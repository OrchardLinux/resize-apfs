import hashlib
import io
import os
import pathlib
import sys
import tempfile
import unittest
import zipfile
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import dopamine_route  # noqa: E402
import tools  # noqa: E402
from access_fixtures import make_ipa, make_payload  # noqa: E402


class FakeSigner:
    def __init__(self, available):
        self.is_available, self.calls, self.payloads = available, [], []

    def available(self):
        return self.is_available

    def install(self, ipa, udid, ask, payload=None):
        self.calls.append((ipa, udid))
        self.payloads.append(payload)


class RunTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.ipa = make_ipa(self.root / 'Dopamine.ipa')
        self.payload = make_payload(self.root / 'payload')

    def run_route(self, signer, devices, asked):
        out = io.StringIO()
        with mock.patch('sys.stdout', out):
            dopamine_route.run(self.ipa, ask=asked.append, signer=signer, devices=devices,
                               work=self.root / 'work', payload=self.payload)
        return out.getvalue()

    def test_the_launcher_signs_for_the_connected_device_and_says_to_open_the_app(self):
        asked, signer = [], FakeSigner(True)
        said = self.run_route(signer, lambda: [(3, 'UDID-1')], asked)
        self.assertEqual(len(asked), 1)
        self.assertIn('Developer Mode', asked[0])
        self.assertEqual(signer.calls, [(self.ipa, 'UDID-1')])
        self.assertEqual(signer.payloads, [self.payload], "another app's payload must reach the signer")
        self.assertIn('Open Resize APFS on the device', said)

    def test_where_nothing_can_sign_the_prepared_app_is_left_for_the_user(self):
        asked = []
        self.run_route(FakeSigner(False), lambda: self.fail('no device needed'), asked)
        self.assertEqual(len(asked), 2)
        self.assertIn('Sign Resize APFS with your Apple ID', asked[1])
        prepared = self.root / 'work/ResizeAPFS.ipa'
        self.assertIn(str(prepared), asked[1])
        with zipfile.ZipFile(prepared) as archive:
            self.assertIn('Payload/Dopamine.app/Frameworks/ResizeAccess.dylib', archive.namelist())

    def test_nothing_is_asked_when_the_folder_has_no_app(self):
        asked = []
        with self.assertRaisesRegex(ValueError, 'out/device/access'):
            dopamine_route.run(self.ipa, ask=asked.append, signer=FakeSigner(True), payload=self.root / 'missing')
        self.assertEqual(asked, [])

    def test_the_user_never_reads_the_word_jailbreak(self):
        asked = []
        said = self.run_route(FakeSigner(False), None, asked)
        for text in asked + [said]:
            self.assertNotIn('jailbreak', text.lower())
            self.assertNotIn('Dopamine', text)

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
