import hashlib
import io
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))

import checkra1n_route  # noqa: E402
import dopamine_route  # noqa: E402
import tools  # noqa: E402


class Recorder:
    """Records each SSH call's remote command line, its input and the ssh options."""

    def __init__(self, failing=()):
        self.argvs, self.commands, self.inputs, self.failing = [], [], [], failing

    def __call__(self, argv, **kwargs):
        self.argvs.append(argv)
        self.commands.append(argv[-1])
        self.inputs.append(kwargs.get('input'))
        code = 1 if any(f in argv[-1] for f in self.failing) else 0
        return subprocess.CompletedProcess(argv, code, b'', b'denied' if code else b'')


def unwrap(command):
    """The script inside `sudo -k -S -p '' /var/jb/bin/sh -c SCRIPT`."""
    words = shlex.split(command)
    assert words[:6] == [dopamine_route.SUDO, '-k', '-S', '-p', '', dopamine_route.SHELL] and words[6] == '-c', words
    return words[7]


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = pathlib.Path(self.temporary.name)
        app = self.work / 'payload/ResizeAPFS.app'
        app.mkdir(parents=True)
        (app / 'ResizeAPFS').write_bytes(b'binary')
        (app / 'ResizeAPFS').chmod(0o755)
        (app / 'Info.plist').write_bytes(b'plist')
        (self.work / 'payload/resize-helper').write_bytes(b'helper')
        self.app, self.helper = checkra1n_route.payload(self.work / 'payload')

    def test_logs_in_as_mobile_on_port_22(self):
        recorder = Recorder()
        dopamine_route.session_for(self.work, 'alpine', run=recorder).sh('true', 'Test')
        argv = recorder.argvs[0]
        self.assertEqual(argv[-2], 'mobile@iphone')
        proxy = next(o for o in argv if o.startswith('ProxyCommand='))
        self.assertEqual(shlex.split(proxy.split('=', 1)[1])[-1], '22')

    def test_every_command_runs_as_root_through_sudo_with_the_password_first(self):
        recorder = Recorder()
        session = dopamine_route.session_for(self.work, 'secret', run=recorder)
        session.put_file(self.helper, '/private/var/ResizeAPFS/resize-helper', 0o755)
        script = unwrap(recorder.commands[0])
        self.assertTrue(script.startswith(f'PATH={dopamine_route.PATH}; export PATH; '), script)
        self.assertIn('cat > /private/var/ResizeAPFS/resize-helper && chmod 755', script)
        # sudo reads the password line; the file follows it unread.
        self.assertEqual(recorder.inputs[0], b'secret\nhelper')

    def test_a_command_without_input_still_gets_the_password(self):
        recorder = Recorder()
        dopamine_route.session_for(self.work, 'alpine', run=recorder).sh('true', 'Test')
        self.assertEqual(recorder.inputs[0], b'alpine\n')

    def test_the_bootstrap_tools_come_first_on_the_path(self):
        self.assertTrue(dopamine_route.PATH.startswith('/var/jb/usr/bin:/var/jb/bin:'))

    def test_install_writes_only_to_the_session_folder(self):
        recorder = Recorder()
        checkra1n_route.install(dopamine_route.session_for(self.work, 'alpine', run=recorder), self.app, self.helper)
        for command in recorder.commands:
            script = unwrap(command).split('export PATH; ', 1)[1]
            for word in shlex.split(script.replace(';', ' ').replace('&&', ' ')):
                if word.startswith('/'):
                    self.assertTrue(word.startswith('/private/var/ResizeAPFS'), script)
        self.assertEqual(unwrap(recorder.commands[-1]).split('export PATH; ', 1)[1],
                         '/private/var/ResizeAPFS/resize-helper --register-app /private/var/ResizeAPFS/ResizeAPFS.app')

    def test_the_server_is_named_in_errors(self):
        session = dopamine_route.session_for(self.work, 'alpine', run=lambda argv, **k: subprocess.CompletedProcess(argv, 255, '', 'refused'))
        with self.assertRaisesRegex(ValueError, "Dopamine's SSH server did not accept the connection: refused"):
            session.open()


class FakeSession:
    def __init__(self, password, accepted, error='Permission denied (publickey,password).'):
        self.password, self.accepted, self.error = password, accepted, error

    def open(self):
        if self.password != self.accepted:
            raise ValueError("Dopamine's SSH server did not accept the connection: " + self.error)


class ConnectTests(unittest.TestCase):
    def test_the_default_password_is_tried_first(self):
        session = dopamine_route.connect('w', secret=lambda prompt: self.fail('asked'),
                                         open_session=lambda p: FakeSession(p, 'alpine'))
        self.assertEqual(session.password, 'alpine')

    def test_a_refused_default_asks_for_the_users_password(self):
        with mock.patch('sys.stdout', io.StringIO()):
            session = dopamine_route.connect('w', secret=lambda prompt: 'mine', open_session=lambda p: FakeSession(p, 'mine'))
        self.assertEqual(session.password, 'mine')

    def test_other_failures_do_not_ask_for_a_password(self):
        with self.assertRaisesRegex(ValueError, 'Connection refused'):
            dopamine_route.connect('w', secret=lambda prompt: self.fail('asked'),
                                   open_session=lambda p: FakeSession(p, 'mine', error='Connection refused'))


class FakeSigner:
    def __init__(self, available):
        self.is_available, self.calls = available, []

    def available(self):
        return self.is_available

    def install(self, ipa, udid, ask):
        self.calls.append((ipa, udid))


class PrepareTests(unittest.TestCase):
    def test_without_xcode_developer_mode_then_signing_are_confirmed(self):
        asked = []
        out = io.StringIO()
        with mock.patch('sys.stdout', out):
            dopamine_route.prepare('/cache/files/sha256-abc', ask=asked.append, signer=FakeSigner(False),
                                   devices=lambda: self.fail('no device needed'))
        self.assertEqual(len(asked), 2)
        self.assertIn('Developer Mode', asked[0])
        self.assertIn('Sign Dopamine with your Apple ID', asked[1])
        self.assertIn('/cache/files/sha256-abc', asked[1])
        self.assertIn('tap Jailbreak', out.getvalue())

    def test_with_xcode_the_launcher_signs_for_the_connected_device(self):
        asked, signer = [], FakeSigner(True)
        with mock.patch('sys.stdout', io.StringIO()):
            dopamine_route.prepare('/ipa', ask=asked.append, signer=signer, devices=lambda: [(3, 'UDID-1')])
        self.assertEqual(len(asked), 1)
        self.assertIn('Developer Mode', asked[0])
        self.assertEqual(signer.calls, [('/ipa', 'UDID-1')])

    def test_exactly_one_device_must_be_connected(self):
        with self.assertRaisesRegex(ValueError, 'No iOS device'):
            dopamine_route.device(lambda: [])
        with self.assertRaisesRegex(ValueError, 'More than one'):
            dopamine_route.device(lambda: [(1, 'a'), (2, 'b')])


class DopaminePinTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)

    def test_the_release_ipa_is_pinned_for_every_computer(self):
        for system in ('macos', 'linux'):
            for arch in ('arm64', 'x86_64'):
                pin = tools.PINS[('dopamine', system, arch)]
                self.assertEqual(pin['url'], 'https://github.com/opa334/Dopamine/releases/download/3.0.13/Dopamine.ipa')
                self.assertEqual(pin['size'], 55_422_988)

    def test_provide_returns_the_verified_file_without_unpacking(self):
        data = b'PK fake ipa'
        pin = dict(tools.DOPAMINE, size=len(data), sha256=hashlib.sha256(data).hexdigest())
        with mock.patch.dict(tools.PINS, {('dopamine', *tools.host()): pin}), mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop('DOPAMINE', None)
            with mock.patch('sys.stdout', io.StringIO()):
                path = tools.provide('dopamine', self.root, fetch=lambda url, dest, size: dest.write_bytes(data))
        self.assertEqual(path, self.root / 'files' / ('sha256-' + pin['sha256']))
        self.assertEqual(path.read_bytes(), data)
        self.assertFalse((self.root / 'tools').exists())

    def test_the_developer_override_names_another_ipa(self):
        ipa = self.root / 'Dopamine.ipa'
        ipa.write_bytes(b'own build')
        with mock.patch.dict(os.environ, {'DOPAMINE': str(ipa)}):
            self.assertEqual(tools.provide('dopamine', self.root, fetch=lambda *a: self.fail('downloaded')), ipa.resolve())


if __name__ == '__main__':
    unittest.main()
