import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
import sys
sys.path.insert(0, str(ROOT / 'scripts'))
import checkra1n


class Checkra1nTests(unittest.TestCase):
    def test_helper_binary_missing_raises(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError):
                checkra1n.helper_binary(pathlib.Path(temporary))

    def test_helper_binary_reports_hash_and_size(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            binary = root / 'out/device/resize-helper-ios12'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'test-binary')
            info = checkra1n.helper_binary(root)
            self.assertEqual(info['bytes'], 11)
            self.assertEqual(len(info['sha256']), 64)

    def test_ssh_and_scp_commands_quote_arguments(self):
        scp = checkra1n.scp_command('/tmp/bin', 'root@127.0.0.1', port=2023, identity='/tmp/id')
        self.assertEqual(scp[:4], ['scp', '-P', '2023', '-i'])
        self.assertEqual(scp[-1], 'root@127.0.0.1:/var/root/resize-helper-ios12')
        cmd = checkra1n.remote_helper_command('root@127.0.0.1', ['--shrink-to', '10GiB'], port=2023)
        self.assertEqual(cmd[:4], ['ssh', '-p', '2023', 'root@127.0.0.1'])
        self.assertIn('--shrink-to 10GiB', cmd[-1])


if __name__ == '__main__':
    unittest.main()
