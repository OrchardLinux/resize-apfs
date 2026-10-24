import hashlib
import json
import os
import pathlib
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class BootValidationTests(unittest.TestCase):
    def check_boot(self, same_executable=False, same_payload=True, valid_image=True):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / 'scripts').mkdir()
            (root / 'bin').mkdir()
            for name in ['boot-device.sh', 'boot_device.py', 'palera.py', 'image_format.py']:
                shutil.copy2(ROOT / 'scripts' / name, root / 'scripts' / name)
            footer = bytearray(512)
            footer[:4] = b'koly'
            struct.pack_into('>II', footer, 4, 4, 512)
            struct.pack_into('>QQ', footer, 216, 3, 1)
            payload = b'data' + footer
            executable = (b'#!/bin/sh\ncase "$1" in\n'
                          b'--version) echo "Build tag: v2.4"; exit 0;;\n'
                          b'--help) echo "--rootless --override-overlay"; exit 0;;\n'
                          b'*) exit 99;;\nesac\n') + payload
            palera = root / 'bin/palera1n'
            palera.write_bytes(executable)
            palera.chmod(0o755)
            image = root / 'overlay.dmg'
            image.write_bytes(b'test image')
            sha = lambda data: hashlib.sha256(data).hexdigest()
            manifest = {
                'sha256': sha(image.read_bytes()) if valid_image else sha(b'wrong'),
                'palera1n': {
                    'installedBinarySHA256': sha(executable) if same_executable else sha(b'other host'),
                    'embeddedBinpackSHA256': sha(payload) if same_payload else sha(b'other payload'),
                },
            }
            image.with_suffix('.json').write_text(json.dumps(manifest))
            env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'])
            # No --boot: validation must never execute palera1n.
            return subprocess.run(['bash', str(root / 'scripts/boot-device.sh'), '--overlay', str(image)],
                                  env=env, capture_output=True, text=True)

    def test_preparation_executable_is_accepted(self):
        self.assertEqual(self.check_boot(same_executable=True).returncode, 0)

    def test_other_host_with_same_payload_is_accepted(self):
        self.assertEqual(self.check_boot().returncode, 0)

    def test_other_payload_is_rejected(self):
        self.assertNotEqual(self.check_boot(same_payload=False).returncode, 0)

    def test_modified_image_is_rejected(self):
        self.assertNotEqual(self.check_boot(same_executable=True, valid_image=False).returncode, 0)
