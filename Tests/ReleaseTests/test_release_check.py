import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ReleaseCheckTests(unittest.TestCase):
    def audit(self, filename, content):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            target = directory / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            return subprocess.run(
                [sys.executable, str(ROOT / 'scripts/check-release.py'), '--release-dir', str(directory)],
                capture_output=True, text=True,
            )

    def test_clean_file_passes(self):
        self.assertEqual(self.audit('README.md', b'Public instructions').returncode, 0)

    def test_private_spec_is_rejected(self):
        self.assertNotEqual(self.audit('SPEC.md', b'Private planning').returncode, 0)

    def test_binary_build_path_is_rejected(self):
        path = b'/' + b'Users/' + b'builder/project/object.o'
        self.assertNotEqual(self.audit('app', b'\x00' + path + b'\x00').returncode, 0)

    def test_credential_is_rejected_without_printing_it(self):
        token = b'ghp' + b'_' + b'A' * 40
        result = self.audit('config', token)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(token.decode(), result.stderr)

    def test_email_is_rejected(self):
        email = b'person' + b'@' + b'example.invalid'
        self.assertNotEqual(self.audit('notes', email).returncode, 0)

    def test_retina_icon_filename_is_not_an_email(self):
        name = 'AppIcon60x60' + '@' + '2x.png'
        self.assertEqual(self.audit(name, name.encode()).returncode, 0)

    def test_source_check_in_nested_work_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout = pathlib.Path(temporary) / '.work' / 'checkout'
            (checkout / 'scripts').mkdir(parents=True)
            (checkout / 'Sources').mkdir()
            script = checkout / 'scripts/check-release.py'
            shutil.copy2(ROOT / 'scripts/check-release.py', script)
            (checkout / 'Sources/example.swift').write_bytes(b'/' + b'Users/' + b'builder/project/file')
            result = subprocess.run([sys.executable, str(script)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Sources/example.swift', result.stderr)

    def test_provisioning_profile_is_rejected(self):
        self.assertNotEqual(self.audit('embedded.mobileprovision', b'profile').returncode, 0)


if __name__ == '__main__':
    unittest.main()
