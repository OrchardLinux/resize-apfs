import pathlib
import plistlib
import struct
import sys
import tempfile
import unittest
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from image_format import HFSImage, read_udif
from palera import version_from


def image(sectors=1, kind=0x80000005, raw=b'x' * 512):
    count = len(raw) // 512
    compressed = zlib.compress(raw)
    table = bytearray(284)
    table[:4] = b'mish'
    struct.pack_into('>IQQQII', table, 4, 1, 0, count, 0, count, 0xfffffffe)
    struct.pack_into('>III', table, 64, 2, 32, zlib.crc32(raw))
    struct.pack_into('>I', table, 200, 2)
    struct.pack_into('>IIQQQQ', table, 204, kind, 0, 0, count, 0, len(compressed))
    struct.pack_into('>IIQQQQ', table, 244, 0xffffffff, 0, count, 0, len(compressed), 0)
    xml = plistlib.dumps({'resource-fork': {'blkx': [{'Data': bytes(table)}]}})
    footer = bytearray(512)
    footer[:4] = b'koly'
    struct.pack_into('>III', footer, 4, 4, 512, 1)
    struct.pack_into('>QQ', footer, 24, 0, len(compressed))
    struct.pack_into('>III', footer, 80, 2, 32, zlib.crc32(compressed))
    struct.pack_into('>QQ', footer, 216, len(compressed), len(xml))
    struct.pack_into('>III', footer, 352, 2, 32, zlib.crc32(table[72:76]))
    struct.pack_into('>Q', footer, 492, sectors)
    return compressed + xml + footer


class PortableImageTests(unittest.TestCase):
    def read(self, data):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / 'image.dmg'
            path.write_bytes(data)
            return read_udif(path)

    def test_valid_partitionless_image(self):
        self.assertEqual(self.read(image())[0], b'x' * 512)

    def test_zero_sector_footer_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'sector count'):
            self.read(image(sectors=0))

    def test_inconsistent_sector_count_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'sizes disagree'):
            self.read(image(sectors=2))

    def test_unknown_compression_is_not_silently_decoded(self):
        with self.assertRaisesRegex(ValueError, 'Unsupported DMG compression'):
            self.read(image(kind=0x80000007))

    def test_corrupted_data_is_rejected(self):
        data = bytearray(image())
        data[3] ^= 1
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.read(data)

    def test_legacy_library_version_does_not_override_build_tag(self):
        self.assertEqual(version_from('palera1n 2.1\nBuild tag: v2.4'), (2, 4, 0))

    def test_newer_versions_parse_without_a_whitelist(self):
        self.assertEqual(version_from('Build tag: v2.7.1'), (2, 7, 1))

    def test_invalid_version_is_rejected(self):
        with self.assertRaises(ValueError):
            version_from('unknown build')

    def test_invalid_hfs_is_rejected(self):
        with self.assertRaises(ValueError):
            HFSImage(bytes(2048))
