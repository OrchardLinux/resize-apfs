import hashlib
import io
import os
import pathlib
import plistlib
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))

import checkra1n_route  # noqa: E402
import launcher  # noqa: E402
import tools  # noqa: E402
import usbmux  # noqa: E402


def pin_for(data, package='executable'):
    return dict(url='https://example.invalid/tool', size=len(data), sha256=hashlib.sha256(data).hexdigest(),
                package=package, member=None, executable_sha256=None)


class ToolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def test_a_verified_download_lands_under_the_installers_name(self):
        data = b'#!/bin/sh\necho tool\n'
        pin = pin_for(data)
        path = tools.package_path(pin, self.root, fetch=lambda url, dest, size: dest.write_bytes(data))
        self.assertEqual(path, self.root / 'files' / ('sha256-' + pin['sha256']))
        # Cached: a second call fetches nothing.
        self.assertEqual(tools.package_path(pin, self.root, fetch=lambda *a: self.fail('fetched again')), path)

    def test_a_download_with_the_wrong_checksum_is_refused_and_not_kept(self):
        pin = pin_for(b'expected')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            tools.package_path(pin, self.root, fetch=lambda url, dest, size: dest.write_bytes(b'tampered'))
        self.assertEqual(list((self.root / 'files').iterdir()), [])

    def test_provide_unpacks_a_runnable_executable(self):
        data = b'#!/bin/sh\necho ok\n'
        pin = pin_for(data)
        with mock.patch.dict(tools.PINS, {('checkra1n', *tools.host()): pin}), mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop('CHECKRA1N', None)
            path = tools.provide('checkra1n', self.root, fetch=lambda url, dest, size: dest.write_bytes(data))
        self.assertEqual(subprocess.run([path], capture_output=True, text=True).stdout, 'ok\n')

    def test_the_developer_override_skips_the_download(self):
        own = self.root / 'my-checkra1n'
        own.write_text('#!/bin/sh\n')
        own.chmod(0o755)
        with mock.patch.dict(os.environ, {'CHECKRA1N': str(own)}):
            self.assertEqual(tools.provide('checkra1n', self.root, fetch=lambda *a: self.fail('downloaded')), own.resolve())

    def test_palera1n_pins_match_the_graphical_installer(self):
        candidates = [p / 'orchard2/crates/flow/src/assets.rs' for p in ROOT.parents]
        assets = next((c for c in candidates if c.is_file()), None)
        if assets is None:
            self.skipTest('orchard2 is not checked out next to resize-apfs')
        text = assets.read_text()
        for key, pin in tools.PINS.items():
            if key[0] == 'palera1n':
                self.assertIn(pin['sha256'], text)


class VersionChoiceTests(unittest.TestCase):
    def test_the_answer_picks_the_route(self):
        with mock.patch('builtins.input', return_value='2'), mock.patch('sys.stdout', io.StringIO()):
            self.assertEqual(launcher.ios_version(None), 12)
        with mock.patch('builtins.input', return_value='1'), mock.patch('sys.stdout', io.StringIO()):
            self.assertEqual(launcher.ios_version(None), 15)

    def test_the_option_skips_the_question(self):
        with mock.patch('builtins.input', side_effect=AssertionError('asked')):
            self.assertEqual(launcher.ios_version(14), 14)

    def test_older_than_12_and_other_answers_are_refused(self):
        with self.assertRaises(ValueError):
            launcher.ios_version(11)
        with mock.patch('builtins.input', return_value='3'), mock.patch('sys.stdout', io.StringIO()), self.assertRaises(ValueError):
            launcher.ios_version(None)


class OverlayReuseTests(unittest.TestCase):
    def test_an_overlay_from_another_palera1n_is_not_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            overlay = pathlib.Path(directory) / 'release-x.dmg'
            overlay.write_bytes(b'image')
            overlay.with_suffix('.json').write_text('{"palera1n": {"installedBinarySHA256": "old"}}')
            self.assertFalse(launcher.made_by(overlay, {'installedBinarySHA256': 'pinned'}))
            self.assertTrue(launcher.made_by(overlay, {'installedBinarySHA256': 'old'}))
            overlay.with_suffix('.json').unlink()
            self.assertFalse(launcher.made_by(overlay, {'installedBinarySHA256': 'old'}))


class FakeUsbmuxd(threading.Thread):
    """Answers ListDevices and Connect like usbmuxd, then echoes the tunnel back."""

    def __init__(self, path, refuse=False):
        super().__init__(daemon=True)
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(4)
        self.refuse = refuse
        self.connects = []

    def reply(self, conn, message, tag):
        body = plistlib.dumps(message)
        conn.sendall(struct.pack('<IIII', 16 + len(body), 1, 8, tag) + body)

    def run(self):
        while True:
            conn, _ = self.server.accept()
            length, _, _, tag = struct.unpack('<IIII', conn.recv(16))
            body = b''
            while len(body) < length - 16:
                body += conn.recv(length - 16 - len(body))
            message = plistlib.loads(body)
            if message['MessageType'] == 'ListDevices':
                self.reply(conn, {'DeviceList': [{'DeviceID': 7, 'Properties': {'SerialNumber': 'abc', 'ConnectionType': 'USB'}}]}, tag)
                conn.close()
            else:
                self.connects.append((message['DeviceID'], socket.ntohs(message['PortNumber'])))
                self.reply(conn, {'MessageType': 'Result', 'Number': 3 if self.refuse else 0}, tag)
                if not self.refuse:
                    conn.sendall(conn.recv(100))
                conn.close()


class UsbmuxTests(unittest.TestCase):
    def serve(self, refuse=False):
        directory = tempfile.mkdtemp(dir='/tmp')
        self.addCleanup(lambda: (os.path.exists(path) and os.unlink(path), os.rmdir(directory)))
        path = os.path.join(directory, 'mux')
        server = FakeUsbmuxd(path, refuse)
        server.start()
        patcher = mock.patch.object(usbmux, 'SOCKET', path)
        patcher.start()
        self.addCleanup(patcher.stop)
        return server

    def test_lists_the_device_and_tunnels_to_its_port(self):
        server = self.serve()
        self.assertEqual(usbmux.devices(), [(7, 'abc')])
        sock = usbmux.connect(44)
        sock.sendall(b'SSH-2.0-test')
        self.assertEqual(sock.recv(100), b'SSH-2.0-test')
        sock.close()
        self.assertEqual(server.connects, [(7, 44)])

    def test_a_refused_port_is_reported(self):
        self.serve(refuse=True)
        with self.assertRaisesRegex(usbmux.UsbmuxError, 'refused'):
            usbmux.connect(44)

    def test_a_missing_service_is_explained(self):
        with mock.patch.object(usbmux, 'SOCKET', '/nonexistent/usbmuxd'), self.assertRaisesRegex(usbmux.UsbmuxError, 'usbmuxd'):
            usbmux.devices()


class Recorder:
    def __init__(self, failing=()):
        self.commands, self.inputs, self.failing = [], [], failing

    def __call__(self, argv, **kwargs):
        script = argv[-1]
        self.commands.append(script)
        self.inputs.append(kwargs.get('input'))
        code = 1 if any(f in script for f in self.failing) else 0
        return subprocess.CompletedProcess(argv, code, b'', b'denied' if code else b'')


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = pathlib.Path(self.temporary.name)
        app = self.work / 'payload/ResizeAPFS.app'
        (app / 'Base.lproj').mkdir(parents=True)
        (app / 'ResizeAPFS').write_bytes(b'binary')
        (app / 'ResizeAPFS').chmod(0o755)
        (app / 'Info.plist').write_bytes(b'plist')
        (app / 'Base.lproj/Main.strings').write_bytes(b'strings')
        (self.work / 'payload/resize-helper').write_bytes(b'helper')
        self.app, self.helper = checkra1n_route.payload(self.work / 'payload')

    def test_install_copies_every_file_with_its_mode_then_registers(self):
        recorder = Recorder()
        session = checkra1n_route.Session(self.work, run=recorder)
        checkra1n_route.install(session, self.app, self.helper)
        joined = '\n'.join(recorder.commands)
        self.assertIn('cat > /var/root/ResizeAPFS/session/resize-helper && chmod 755', joined)
        self.assertIn('cat > /Applications/ResizeAPFS.app/ResizeAPFS && chmod 755', joined)
        self.assertIn('cat > /Applications/ResizeAPFS.app/Info.plist && chmod 644', joined)
        self.assertIn('/Applications/ResizeAPFS.app/Base.lproj', joined)
        self.assertIn(b'helper', recorder.inputs)
        self.assertEqual(recorder.commands[-1], '/var/root/ResizeAPFS/session/resize-helper --register-app /Applications/ResizeAPFS.app')

    def test_a_failing_step_names_itself(self):
        session = checkra1n_route.Session(self.work, run=Recorder(failing=('--register-app',)))
        with self.assertRaisesRegex(ValueError, 'Adding the app to the home screen failed on the device: denied'):
            checkra1n_route.install(session, self.app, self.helper)

    def test_cleanup_stops_the_helper_unregisters_and_deletes(self):
        recorder = Recorder()
        session = checkra1n_route.Session(self.work, run=recorder)
        process = mock.Mock()
        checkra1n_route.finish(session, process)
        self.assertIn('kill', recorder.commands[0])
        self.assertEqual(recorder.commands[-1], '/var/root/ResizeAPFS/session/resize-helper --unregister-app '
                         '/Applications/ResizeAPFS.app; rm -rf /Applications/ResizeAPFS.app /var/root/ResizeAPFS/session')
        process.wait.assert_called_once()

    def test_the_session_never_saves_a_host_key_or_offers_our_keys(self):
        session = checkra1n_route.Session(self.work, run=Recorder())
        self.assertIn('UserKnownHostsFile=/dev/null', session.base)
        self.assertIn('PubkeyAuthentication=no', session.base)
        self.assertTrue(any(a.startswith('ProxyCommand=') and 'usbmux.py' in a and ' 44' in a for a in session.base))

    def test_a_release_without_the_ios12_app_says_so(self):
        with self.assertRaisesRegex(ValueError, 'no iOS 12-14 app'):
            checkra1n_route.payload(self.work / 'missing')

    def test_waiting_gives_up_with_advice(self):
        clock = iter(range(0, 1000, 100))
        with mock.patch.object(usbmux, 'connect', side_effect=usbmux.UsbmuxError('No iOS device is connected over USB.')), \
                mock.patch('sys.stdout', io.StringIO()):
            with self.assertRaisesRegex(ValueError, 'did not come up'):
                checkra1n_route.wait_for_ssh(timeout=300, sleep=lambda s: None, now=lambda: next(clock))


if __name__ == '__main__':
    unittest.main()
