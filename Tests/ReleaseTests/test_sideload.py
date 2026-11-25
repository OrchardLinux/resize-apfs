import datetime
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))

import sideload  # noqa: E402
import tools  # noqa: E402


def done(stdout='', code=0):
    return subprocess.CompletedProcess([], code, stdout, '')


def make_ipa(path, bootstraps=('1800', '1900')):
    with zipfile.ZipFile(path, 'w') as archive:
        executable = zipfile.ZipInfo('Payload/Dopamine.app/Dopamine')
        executable.external_attr = 0o755 << 16
        archive.writestr(executable, b'\xcf\xfa\xed\xfe binary')
        archive.writestr('Payload/Dopamine.app/Info.plist', b'plist')
        for version in bootstraps:
            archive.writestr(f'Payload/Dopamine.app/bootstrap_{version}.tar.zst', b'plain ' + version.encode())


class XtoolTests(unittest.TestCase):
    def test_xtool_is_pinned_for_every_supported_computer(self):
        for system in ('macos', 'linux'):
            for arch in ('arm64', 'x86_64'):
                pin = tools.PINS[('xtool', system, arch)]
                self.assertIn('/xtool-org/xtool/releases/download/2.0.0-beta.2/', pin['url'])
        self.assertEqual(tools.PINS[('xtool', 'macos', 'arm64')]['member'], 'xtool.app/Contents/MacOS/xtool')
        self.assertTrue(sideload.available(host=lambda: ('linux', 'x86_64')))
        self.assertFalse(sideload.available(host=lambda: ('windows', 'x86_64')))

    def test_xtool_runs_its_command_line_without_fuse(self):
        env = sideload.environment()
        self.assertEqual(env['XTL_CLI'], '1')
        self.assertEqual(env['APPIMAGE_EXTRACT_AND_RUN'], '1')

    def test_sign_in_is_asked_only_when_logged_out(self):
        self.assertTrue(sideload.logged_in('xtool', run=lambda *a, **k: done('Logged in.\ntoken')))
        self.assertFalse(sideload.logged_in('xtool', run=lambda *a, **k: done('Logged out')))
        calls = []
        with mock.patch('sys.stdout', io.StringIO()):
            sideload.log_in('xtool', run=lambda argv, **k: calls.append(argv) or done())
        self.assertEqual(calls, [['xtool', 'auth', 'login', '--mode', 'password']])

    def test_a_failed_sign_in_stops(self):
        with mock.patch('sys.stdout', io.StringIO()), self.assertRaisesRegex(ValueError, 'Signing in'):
            sideload.log_in('xtool', run=lambda *a, **k: done(code=1))


class PreparedIpaTests(unittest.TestCase):
    def test_bootstraps_are_swapped_and_modes_kept(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = pathlib.Path(folder)
            make_ipa(folder / 'in.ipa')
            replacements = {}
            for v in ('1800', '1900'):
                (folder / v).write_bytes(b'ssh ' + v.encode())
                replacements[v] = folder / v
            out = sideload.prepared_ipa(folder / 'in.ipa', folder / 'work', replacements)
            with zipfile.ZipFile(out) as archive:
                self.assertEqual(archive.read('Payload/Dopamine.app/bootstrap_1800.tar.zst'), b'ssh 1800')
                self.assertEqual(archive.read('Payload/Dopamine.app/bootstrap_1900.tar.zst'), b'ssh 1900')
                self.assertEqual(archive.getinfo('Payload/Dopamine.app/Dopamine').external_attr >> 16 & 0o777, 0o755)

    def test_an_unpinned_bootstrap_version_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = pathlib.Path(folder)
            make_ipa(folder / 'in.ipa', bootstraps=('2000',))
            with self.assertRaisesRegex(ValueError, 'version 2000'):
                sideload.prepared_ipa(folder / 'in.ipa', folder / 'work', {})

    def test_both_bundled_versions_are_pinned(self):
        self.assertEqual(sorted(tools.BOOTSTRAP_SSH), ['1800', '1900'])


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        make_ipa(self.root / 'Dopamine.ipa')
        self.replacements = {}
        for v in ('1800', '1900'):
            (self.root / v).write_bytes(b'ssh ' + v.encode())
            self.replacements[v] = self.root / v
        self.calls = []
        self.team = False  # xtool, unless a test gives Xcode's account

    def run_tool(self, argv, **kwargs):
        self.calls.append([str(a) for a in argv])
        if argv[1:3] == ['auth', 'status']:
            return done('Logged out')
        return done()

    def install(self, asked):
        with mock.patch('sys.stdout', io.StringIO()), mock.patch.object(sideload, 'describe', lambda udid, run: 'XR'):
            sideload.install(self.root / 'Dopamine.ipa', 'UDID-1', ask=asked.append, run=self.run_tool,
                             root=self.root, replacements=self.replacements, provide=lambda tool: 'xtool', team=self.team)

    def test_one_confirmation_then_sign_in_and_install_on_that_device(self):
        asked = []
        self.install(asked)
        self.assertEqual(len(asked), 1)
        self.assertIn('install it on XR', asked[0])
        self.assertEqual(self.calls[1], ['xtool', 'auth', 'login', '--mode', 'password'])
        self.assertEqual(self.calls[2][:5], ['xtool', 'install', '--usb', '--udid', 'UDID-1'])
        record = json.loads(sideload.record_path('UDID-1', self.root).read_text())
        self.assertIn('expires', record)

    def test_a_still_signed_copy_is_not_signed_again(self):
        self.install([])
        self.calls.clear()
        asked = []
        with mock.patch.object(sideload, 'installed', lambda *a: None):
            self.install(asked)
        self.assertEqual(asked, [])
        self.assertEqual(self.calls, [])

    def test_an_app_removed_from_the_device_is_signed_again(self):
        self.install([])
        asked = []
        with mock.patch.object(sideload, 'installed', lambda *a: False):
            self.install(asked)
        self.assertEqual(len(asked), 1)

    def test_xcodes_account_signs_without_xtool_or_a_new_sign_in(self):
        self.team = ('ABCDE12345', 'Someone (Personal Team)', True)
        signed = []
        when = datetime.datetime(2026, 12, 3, tzinfo=datetime.timezone.utc)
        def xcode(prepared, work, team, identifier, udid, run):
            signed.append((team, identifier, udid))
            with zipfile.ZipFile(prepared) as archive:
                self.assertEqual(archive.read('Payload/Dopamine.app/bootstrap_1900.tar.zst'), b'ssh 1900')
            return when
        asked = []
        with mock.patch.object(sideload, 'install_with_xcode', xcode):
            self.install(asked)
        self.assertIn('the Apple ID Xcode is signed in to (Someone (Personal Team))', asked[0])
        self.assertEqual(signed, [('ABCDE12345', 'dev.orchard.dopamine.abcde12345', 'UDID-1')])
        self.assertEqual(self.calls, [], 'xtool is not used')

    def test_no_xcode_account_means_xtool(self):
        with mock.patch.object(sys, 'platform', 'linux'):
            self.assertIsNone(sideload.xcode_team(run=lambda *a, **k: self.fail('asked')))
        with mock.patch.object(sys, 'platform', 'darwin'), mock.patch.object(sideload.xcode_signing, 'teams', lambda run: []):
            self.assertIsNone(sideload.xcode_team(run=lambda *a, **k: done()))

    def test_a_failed_install_records_nothing(self):
        self.run_tool = lambda argv, **k: done('Logged in.') if argv[1:3] == ['auth', 'status'] else done(code=1)
        with self.assertRaisesRegex(ValueError, 'xtool exit status 1'):
            self.install([])
        self.assertFalse(sideload.record_path('UDID-1', self.root).exists())


class StillSignedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.now = datetime.datetime(2026, 11, 26, tzinfo=datetime.timezone.utc)

    def record(self, days, key='k'):
        path = sideload.record_path('UDID', self.root)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'expires': (self.now + datetime.timedelta(days=days)).isoformat(), 'key': key}))

    def check(self, present=None):
        with mock.patch.object(sideload, 'installed', lambda *a: present):
            return sideload.still_signed('k', 'UDID', now=self.now, root=self.root)

    def test_days_left_keep_it(self):
        self.record(5)
        self.assertIsNotNone(self.check())
        self.assertIsNotNone(self.check(present=True))

    def test_less_than_a_day_another_build_or_a_removed_app_sign_again(self):
        self.record(0.5)
        self.assertIsNone(self.check())
        self.record(5, key='other')
        self.assertIsNone(self.check())
        self.record(5)
        self.assertIsNone(self.check(present=False))

    def test_no_record_signs(self):
        self.assertIsNone(self.check())


class InstalledTests(unittest.TestCase):
    def test_xtools_app_id_prefix_is_matched(self):
        def run(argv, **kwargs):
            out = pathlib.Path(argv[argv.index('--json-output') + 1])
            out.write_text(json.dumps({'result': {'apps': [{'bundleIdentifier': 'XTL-ABCD.com.opa334.Dopamine'}]}}))
            return done()
        with mock.patch.object(sys, 'platform', 'darwin'):
            self.assertTrue(sideload.installed('UDID', 'com.opa334.Dopamine', run))
        with mock.patch.object(sys, 'platform', 'linux'):
            self.assertIsNone(sideload.installed('UDID', 'com.opa334.Dopamine', run))


if __name__ == '__main__':
    unittest.main()
