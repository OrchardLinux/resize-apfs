"""Host-only regression tests; all executable/image fixtures are synthetic."""
import contextlib
import hashlib
import io
import json
import os
import pathlib
import runpy
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from palera_fixtures import ARM64, X86_64, elf, overlay, thin, universal

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from boot_device import command
from image_format import HFSImage, read_udif
from palera import discover, embedded_images, executable_slice


def sha(data):
    return hashlib.sha256(data).hexdigest()


class UniversalPaleraTests(unittest.TestCase):
    def setUp(self):
        contexts = contextlib.ExitStack()
        self.addCleanup(contexts.close)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name).resolve()
        self.binary = self.root / 'palera1n'
        self.output = self.root / 'overlay.dmg'
        self.arm = overlay(b'arm overlay')
        self.intel = overlay(b'intel overlay')
        self.fat = universal([thin(self.intel, X86_64), thin(self.arm)])
        self.binary.write_bytes(self.fat)
        contexts.enter_context(patch('palera.platform.machine', return_value='arm64'))
        contexts.enter_context(patch.dict(os.environ, PALERA1N=str(self.binary)))
        # Only capability probes are simulated. Never run a fixture or palera1n.
        self.probes = contexts.enter_context(patch('palera.subprocess.run', side_effect=self.probe))
        self.execv = contexts.enter_context(patch('os.execv', side_effect=AssertionError('Must not boot')))

    def probe(self, argv, **kwargs):
        self.assertEqual(argv[0], str(self.binary))
        self.assertIn(argv[1], ('--version', '--help'))
        text = 'Build tag: v2.4' if argv[1] == '--version' else '--rootless --override-overlay'
        return subprocess.CompletedProcess(argv, 0, stdout=text, stderr='')

    def extract(self):
        with patch.object(sys, 'argv', ['extract-binpack.py', '--output', str(self.output)]), contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(ROOT / 'scripts/extract-binpack.py'), run_name='__main__')
        return json.loads(self.output.with_suffix('.json').read_text())

    def prepare(self):
        producer = self.extract()
        # Stand in for the assembled custom image; command() must verify its hash.
        self.output.write_bytes(b'prepared custom overlay')
        self.output.with_suffix('.json').write_text(json.dumps({
            'sha256': sha(self.output.read_bytes()), 'palera1n': producer}))
        return producer

    def boot_command(self):
        with patch('boot_device.sys.platform', 'darwin'):
            return command(self.output, discover())

    def test_selects_host_slice_in_all_fat_encodings(self):
        for endian in ('>', '<'):
            for wide in (False, True):
                for host, expected in [('arm64', self.arm), ('x86_64', self.intel)]:
                    with self.subTest(endian=endian, wide=wide, host=host), patch('palera.platform.machine', return_value=host):
                        self.binary.write_bytes(universal([thin(self.intel, X86_64), thin(self.arm)], endian, wide))
                        self.assertEqual(list(embedded_images(self.binary)), [expected])

    def test_identical_overlays_in_two_slices_extract_once(self):
        self.binary.write_bytes(universal([thin(self.arm, X86_64), thin(self.arm)]))
        producer = self.extract()
        self.assertEqual(self.output.read_bytes(), self.arm)
        self.assertEqual(producer['embeddedBinpackSHA256'], sha(self.arm))
        self.assertEqual(producer['installedBinarySHA256'], sha(self.binary.read_bytes()))

    def test_thin_macho_and_linux_elf_keep_existing_behavior(self):
        for data in (thin(self.arm), thin(self.arm, X86_64), elf(self.arm)):
            with self.subTest(magic=data[:4]):
                self.binary.write_bytes(data)
                self.assertEqual(list(embedded_images(self.binary)), [self.arm])
                self.extract()
                self.assertEqual(self.output.read_bytes(), self.arm)

    def test_extraction_keeps_real_udif_and_hfs_validation(self):
        self.extract()
        raw, _ = read_udif(self.output)
        self.assertEqual(HFSImage(raw).read('/loader.dmg'), b'arm overlay')
        damaged = bytearray(self.arm)
        damaged[3] ^= 1
        for image, message in [(bytes(damaged), 'checksum'),
                               (overlay(omit='/bin/launchctl'), 'Missing required boot'),
                               (overlay(daemon=b'wrong'), 'Unsupported daemon layout')]:
            with self.subTest(message=message):
                self.binary.write_bytes(universal([thin(self.intel, X86_64), thin(image)]))
                with contextlib.redirect_stderr(io.StringIO()) as errors, self.assertRaises(SystemExit):
                    self.extract()
                self.assertIn(message, errors.getvalue())

    def test_multiple_overlays_in_selected_slice_remain_ambiguous(self):
        for extra in (self.arm, self.intel):
            self.binary.write_bytes(universal([thin(self.intel, X86_64), thin(self.arm + extra)]))
            with contextlib.redirect_stderr(io.StringIO()) as errors, self.assertRaises(SystemExit):
                self.extract()
            self.assertIn('No unique compatible palera1n overlay', errors.getvalue())
            self.assertFalse(self.output.exists())

    def test_images_outside_selected_slice_are_ignored(self):
        self.binary.write_bytes(universal([thin(self.intel, X86_64), thin(b'no image')]) + self.arm)
        self.assertEqual(list(embedded_images(self.binary)), [])
        # Footer tries to reach backward into a different slice.
        footer = bytearray(self.arm[-512:])
        struct.pack_into('>QQ', footer, 216, 100, 1)
        self.binary.write_bytes(universal([thin(self.intel, X86_64), thin(footer)]))
        self.assertEqual(list(embedded_images(self.binary)), [])

    def test_missing_unsupported_and_ambiguous_architectures(self):
        with patch('palera.platform.machine', return_value='riscv64'), self.assertRaisesRegex(ValueError, 'Unsupported.*host architecture'):
            executable_slice(self.fat)
        for parts, message in [([thin(self.intel, X86_64)], 'no slice'),
                               ([thin(self.arm), thin(self.intel)], 'multiple slices'),
                               ([thin(self.arm, ARM64, 2)], 'CPU subtype')]:
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                executable_slice(universal(parts))

    def test_malformed_fat_metadata_is_rejected_before_execution(self):
        offset = struct.unpack_from('>I', self.fat, 16)[0]
        cases = [(self.fat[:4], 'truncated header'), (self.fat[:27], 'architecture table')]

        def changed(at, value, message, fmt='>I'):
            data = bytearray(self.fat)
            struct.pack_into(fmt, data, at, value)
            cases.append((data, message))

        changed(4, 0, 'architecture table')
        changed(4, 0xffffffff, 'architecture table')
        changed(16, 8, 'out of bounds')
        changed(20, len(self.fat), 'out of bounds')
        changed(20, 0, 'out of bounds')
        changed(24, 32, 'alignment')
        changed(24, 10, 'alignment')
        changed(offset, 0, 'not a thin Mach-O')
        changed(offset + 4, ARM64, 'architecture disagrees', '<I')
        changed(offset + 8, 99, 'architecture disagrees', '<I')
        changed(offset + 12, 1, 'not an executable', '<I')
        changed(offset + 16, 1, 'load commands', '<I')
        changed(offset + 20, len(self.fat), 'load commands', '<I')
        overlap = bytearray(self.fat)
        overlap[28:48] = overlap[8:28]
        cases.append((overlap, 'overlapping slices'))
        truncated = bytearray(universal([thin(b'')]))
        struct.pack_into('>I', truncated, 20, 28)
        cases.append((truncated, 'truncated slice header'))
        reserved = bytearray(universal([thin(self.arm)], wide=True))
        struct.pack_into('>I', reserved, 36, 1)
        cases.append((reserved, 'reserved field'))
        for data, message in cases:
            with self.subTest(message=message):
                self.binary.write_bytes(data)
                with self.assertRaisesRegex(ValueError, message):
                    discover()
        self.probes.assert_not_called()

    def test_palera1n_override_version_and_capability_checks(self):
        self.assertEqual(discover()['path'], str(self.binary))
        self.assertEqual(discover()['rootlessArguments'], ['--rootless'])
        for version, help_text, message in [('Build tag: v2.3', '--override-overlay', '2.4 or later'),
                                          ('unknown', '--override-overlay', 'Cannot determine'),
                                          ('Build tag: v2.4', '--rootless', 'custom overlays'),
                                          ('Build tag: v2.4', '--fakefs --override-overlay', 'rootless mode')]:
            self.probes.side_effect = [subprocess.CompletedProcess([], 0, version, ''),
                                       subprocess.CompletedProcess([], 0, help_text, '')]
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                discover()

    def test_prepare_to_boot_command_without_execution(self):
        self.prepare()
        self.assertEqual(self.boot_command(), [str(self.binary), '--rootless', '--override-overlay', str(self.output)])
        self.execv.assert_not_called()

    def test_prepared_image_tampering_is_rejected(self):
        self.prepare()
        self.output.write_bytes(b'modified overlay')
        with self.assertRaisesRegex(ValueError, 'Overlay checksum mismatch'):
            self.boot_command()

    def test_unchanged_fat_binary_on_other_architecture_checks_payload(self):
        self.prepare()
        with patch('palera.platform.machine', return_value='x86_64'), self.assertRaisesRegex(ValueError, 'changed its boot payload'):
            self.boot_command()

    def test_changed_executable_accepts_only_selected_matching_payload(self):
        self.prepare()
        # Same payload with changed executable bytes remains supported.
        self.binary.write_bytes(self.fat + b'new build')
        self.boot_command()
        # A matching payload in the other architecture must not hide a change.
        self.binary.write_bytes(universal([thin(self.arm, X86_64), thin(self.intel)]))
        with self.assertRaisesRegex(ValueError, 'changed its boot payload'):
            self.boot_command()
        self.binary.write_bytes(universal([thin(self.intel, X86_64), thin(self.arm + self.arm)]))
        with self.assertRaisesRegex(ValueError, 'changed its boot payload'):
            self.boot_command()
