"""Host-only tests of the J96 cold-start launcher's input checks. Nothing is booted."""
import hashlib
import json
import pathlib
import struct
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from j96_cold_boot import verify


def sha(data):
    return hashlib.sha256(data).hexdigest()


class J96ColdBootTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.temporary.name)
        footer = bytearray(512)
        footer[:4] = b'koly'
        struct.pack_into('>II', footer, 4, 4, 512)
        struct.pack_into('>QQ', footer, 216, 3, 1)
        self.payload = b'data' + footer
        # palera1n 3.0.0 beta 3 prints a banner rather than a build tag.
        self.executable = (b'#!/bin/sh\ncase "$1" in\n'
                           b'--version) echo ":: Palera1n beta 3.0.0"; exit 0;;\n'
                           b'--help) echo "--cli --rootless --override-overlay"; exit 0;;\n'
                           b'*) exit 99;;\nesac\n') + self.payload
        self.palera1n = root / 'palera1n-beta3'
        self.palera1n.write_bytes(self.executable)
        self.palera1n.chmod(0o755)
        self.cold_probe = root / 'cold-probe.py'
        self.cold_probe.write_text('# stand-in for the J96 cold-start script\n')
        (root / 'live-probe.py').write_text('# stand-in\n')
        self.overlay = root / 'j96.dmg'
        self.overlay.write_bytes(b'test image')
        self.write_manifest()

    def tearDown(self):
        self.temporary.cleanup()

    def write_manifest(self, **changes):
        manifest = {
            'mode': 'inspect', 'sha256': sha(self.overlay.read_bytes()),
            'bytes': self.overlay.stat().st_size, 'networkListenersEnabled': False,
            'deviceBuild': {'minimumOS': '15.0'},
            'palera1n': {'version': '3.0.0', 'installedBinarySHA256': sha(self.executable),
                         'embeddedBinpackSHA256': sha(self.payload)},
        }
        manifest.update(changes)
        self.overlay.with_suffix('.json').write_text(json.dumps(manifest))

    def check(self, **kwargs):
        return verify(self.overlay, self.palera1n, self.cold_probe, **kwargs)

    def test_matching_inspection_overlay_gives_the_proven_command(self):
        argv, manifest = self.check()
        self.assertEqual(manifest['mode'], 'inspect')
        self.assertEqual(argv[:5], ['/usr/bin/sudo', '/usr/bin/env', '-i', 'PATH=/usr/bin:/bin', 'LANG=C'])
        self.assertEqual(argv[5:], [str(self.palera1n.resolve()), '--cli', '--rootless', '--override-overlay',
                                    str(self.overlay.resolve()), '-d', '-n'])

    def test_write_overlay_needs_explicit_permission(self):
        self.write_manifest(mode='write')
        with self.assertRaisesRegex(ValueError, '--allow-write'):
            self.check()
        self.assertEqual(self.check(allow_write=True)[1]['mode'], 'write')

    def test_mismatches_are_rejected(self):
        cases = [
            ({'palera1n': {'version': '3.0.0', 'installedBinarySHA256': sha(b'other'),
                           'embeddedBinpackSHA256': sha(self.payload)}}, 'different palera1n executable'),
            ({'palera1n': {'version': '3.0.0', 'installedBinarySHA256': sha(self.executable),
                           'embeddedBinpackSHA256': sha(b'other payload')}}, 'boot payload'),
            ({'deviceBuild': {'minimumOS': '16.0'}}, 'iOS 15'),
            ({'networkListenersEnabled': True}, 'network'),
            ({'mode': 'format'}, 'Unknown overlay mode'),
            ({'sha256': sha(b'tampered')}, 'checksum'),
            ({'bytes': 1}, 'size mismatch'),
        ]
        for changes, message in cases:
            with self.subTest(message=message):
                self.write_manifest(**changes)
                with self.assertRaisesRegex(ValueError, message):
                    self.check(allow_write=True)

    def test_cold_start_scripts_are_checked(self):
        with self.assertRaisesRegex(ValueError, 'changed since it was pinned'):
            self.check(cold_probe_sha256=sha(b'other'))
        self.assertTrue(self.check(cold_probe_sha256=sha(self.cold_probe.read_bytes())))
        (self.cold_probe.parent / 'live-probe.py').unlink()
        with self.assertRaisesRegex(ValueError, 'live-probe.py'):
            self.check()


if __name__ == '__main__':
    unittest.main()
