import datetime
import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))

import sideload  # noqa: E402

MACHO = b'\xcf\xfa\xed\xfe' + b'\0' * 12


def done(stdout=b'', stderr=b'', code=0):
    return subprocess.CompletedProcess([], code, stdout, stderr)


class TeamTests(unittest.TestCase):
    def test_teams_come_from_xcodes_accounts(self):
        settings = plistlib.dumps({'IDEProvisioningTeamByIdentifier': {'acct': [
            {'teamID': 'ABCDE12345', 'teamName': 'Someone (Personal Team)', 'isFreeProvisioningTeam': True}]}})
        self.assertEqual(sideload.teams(lambda *a, **k: done(settings)), [('ABCDE12345', 'Someone (Personal Team)', True)])

    def test_no_account_says_how_to_add_one(self):
        with self.assertRaisesRegex(ValueError, 'Xcode > Settings > Accounts'):
            sideload.choose_team([])

    def test_one_team_is_used_without_asking(self):
        team = ('ABCDE12345', 'Someone', True)
        self.assertEqual(sideload.choose_team([team], ask=lambda p: self.fail('asked')), team)

    def test_one_bundle_identifier_per_team(self):
        self.assertEqual(sideload.bundle_id('ABCDE12345'), 'dev.orchard.dopamine.abcde12345')


class StubTests(unittest.TestCase):
    def test_the_stub_project_names_team_and_identifier(self):
        with tempfile.TemporaryDirectory() as folder:
            project = sideload.write_stub(folder, 'ABCDE12345', 'dev.orchard.dopamine.abcde12345')
            text = (project / 'project.pbxproj').read_text()
            scheme = next((project / 'xcshareddata/xcschemes').iterdir()).read_text()
        self.assertIn('DEVELOPMENT_TEAM = ABCDE12345;', text)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = "dev.orchard.dopamine.abcde12345";', text)
        self.assertNotIn('@', text.replace('// !$*UTF8*$!', ''))
        self.assertNotIn('@', scheme)

    def test_xcode_may_register_the_device_and_update_profiles(self):
        command = sideload.stub_command(pathlib.Path('p.xcodeproj'), 'UDID', pathlib.Path('d'))
        self.assertIn('-allowProvisioningUpdates', command)
        self.assertIn('-allowProvisioningDeviceRegistration', command)
        self.assertIn('id=UDID', command)

    def test_the_valid_identity_is_picked_over_an_expired_one_with_its_name(self):
        listing = ('  1) ' + 'A' * 40 + ' "Apple Development: x (Y)"\n     1 valid identities found\n')
        self.assertEqual(sideload.identity('Apple Development: x (Y)', lambda *a, **k: done(listing, '')), 'A' * 40)


class SignOrderTests(unittest.TestCase):
    def test_nested_code_is_signed_before_its_bundle_and_the_main_executable_last(self):
        with tempfile.TemporaryDirectory() as folder:
            app = pathlib.Path(folder) / 'Dopamine.app'
            (app / 'Frameworks/kfd.framework').mkdir(parents=True)
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Dopamine'}))
            (app / 'Dopamine').write_bytes(MACHO)
            (app / 'libjailbreak.dylib').write_bytes(MACHO)
            (app / 'basebin.tar').write_bytes(b'not code')
            (app / 'Frameworks/kfd.framework/kfd').write_bytes(MACHO)
            order = [p.relative_to(app).as_posix() for p in sideload.sign_order(app)]
        self.assertEqual(order, ['libjailbreak.dylib', 'Frameworks/kfd.framework'])


class StillSignedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.now = datetime.datetime(2026, 11, 26, tzinfo=datetime.timezone.utc)

    def record(self, days, ipa='sha', device='UDID'):
        path = sideload.record_path('id', self.root)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'expires': (self.now + datetime.timedelta(days=days)).isoformat(), 'ipa': ipa, 'device': device}))

    def check(self, apps=('id',)):
        def run(argv, **kwargs):
            output = pathlib.Path(argv[argv.index('--json-output') + 1])
            output.write_text(json.dumps({'result': {'apps': [{'bundleIdentifier': a} for a in apps]}}))
            return done()
        return sideload.still_signed('id', 'sha', 'UDID', now=self.now, root=self.root, run=run)

    def test_an_installed_copy_with_days_left_is_kept(self):
        self.record(5)
        self.assertIsNotNone(self.check())

    def test_less_than_a_day_left_signs_again(self):
        self.record(0.5)
        self.assertIsNone(self.check())

    def test_another_release_or_device_signs_again(self):
        self.record(5, ipa='other')
        self.assertIsNone(self.check())
        self.record(5, device='OTHER')
        self.assertIsNone(self.check())

    def test_an_app_removed_from_the_device_is_installed_again(self):
        self.record(5)
        self.assertIsNone(self.check(apps=()))

    def test_no_record_signs(self):
        self.assertIsNone(self.check())


if __name__ == '__main__':
    unittest.main()
