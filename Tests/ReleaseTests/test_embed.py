import pathlib
import plistlib
import re
import struct
import sys
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import embed  # noqa: E402
from access_fixtures import macho, make_ipa, make_payload  # noqa: E402


def libraries(data):
    """The libraries a 64-bit Mach-O loads, from its load commands."""
    count, size = struct.unpack_from('<II', data, 16)
    found, offset = [], embed.HEADER
    for _ in range(count):
        command, length = struct.unpack_from('<II', data, offset)
        if command == embed.LC_LOAD_DYLIB:
            start = offset + struct.unpack_from('<I', data, offset + 8)[0]
            found.append(data[start:offset + length].split(b'\0', 1)[0].decode())
        offset += length
    assert offset == embed.HEADER + size
    return found


class LibraryTests(unittest.TestCase):
    def test_the_library_is_added_without_moving_anything(self):
        before = macho()
        after = embed.add_library(before)
        self.assertEqual(libraries(after), [embed.LIBRARY])
        self.assertEqual(len(after), len(before))
        content = len(before) - before.index(b'\0DOJailbreaker\0')
        self.assertEqual(after[-content:], before[-content:], 'the program itself is untouched')

    def test_adding_it_twice_changes_nothing(self):
        once = embed.add_library(macho())
        self.assertEqual(embed.add_library(once), once)

    def test_an_executable_without_room_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'no room'):
            embed.add_library(macho(room=16))

    def test_every_architecture_of_a_universal_executable_gets_it(self):
        one = macho()
        first, second = 4096, 8192
        fat = struct.pack('>II', embed.FAT_MAGIC, 2)
        for offset in (first, second):
            fat += struct.pack('>iiIII', 0x0100000c, 0, offset, len(one), 12)
        fat = fat.ljust(first, b'\0') + one.ljust(second - first, b'\0') + one
        after = embed.add_library(fat)
        self.assertEqual(len(after), len(fat))
        for offset in (first, second):
            self.assertEqual(libraries(after[offset:offset + len(one)]), [embed.LIBRARY])

    def test_something_else_than_a_program_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'not a 64-bit program'):
            embed.add_library(b'PK\x03\x04' + bytes(64))


class InterfaceTests(unittest.TestCase):
    def test_a_release_without_a_call_we_make_is_refused_by_name(self):
        names = [name for name in embed.INTERFACE + (embed.SETTING,) if name != 'runAsRoot:']
        with self.assertRaisesRegex(ValueError, 'it has no runAsRoot:'):
            embed.check_interface(macho(names))
        embed.check_interface(macho())

    def test_the_checked_names_are_the_ones_the_header_declares(self):
        header = (ROOT / 'Access/DopamineInterface.h').read_text()
        classes = re.findall(r'@interface (\w+)', header)
        selectors = []
        for declaration in re.findall(r'^[-+] \([^)]*\)\s*([^;]+);', header, re.M):
            parts = re.findall(r'(\w+)\s*:', declaration)
            selectors.append(''.join(part + ':' for part in parts) if parts else declaration.strip())
        self.assertEqual(sorted(embed.INTERFACE), sorted(set(classes + selectors)))

    def test_the_first_run_asks_for_no_password(self):
        # Set before the run, so the bootstrap's setup script inherits it.
        bridge = (ROOT / 'Access/AccessBridge.m').read_text()
        self.assertLess(bridge.index('setenv("NO_PASSWORD_PROMPT", "1", 1)'), bridge.index('runWithError:&error'))

    def test_the_bridge_names_no_other_dopamine_class(self):
        bridge = (ROOT / 'Access/AccessBridge.m').read_text()
        named = set(re.findall(r'\bDO[A-Z]\w+', bridge))
        self.assertEqual(named, {'DOJailbreaker', 'DOEnvironmentManager', 'DOPreferenceManager'})
        self.assertIn(f'@"{embed.SETTING}"', bridge)


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.payload = make_payload(self.root / 'payload')
        self.ipa = make_ipa(self.root / 'Dopamine.ipa')

    def prepared(self):
        return zipfile.ZipFile(embed.prepared_ipa(self.ipa, self.root / 'work', self.payload))

    def test_the_app_is_resize_apfs_with_dopamine_unchanged_underneath(self):
        with self.prepared() as archive:
            app = 'Payload/Dopamine.app/'
            info = plistlib.loads(archive.read(app + 'Info.plist'))
            self.assertEqual(info['CFBundleDisplayName'], 'Resize APFS')
            self.assertEqual(info['UIAppFonts'], ['Fonts/Mono.ttf'])
            self.assertNotIn(embed.SCENES, info, "Dopamine's own interface must not start")
            self.assertNotIn('NSPhotoLibraryUsageDescription', info)
            self.assertEqual(info['CFBundleExecutable'], 'Dopamine')
            self.assertEqual(info['CFBundleIdentifier'], 'com.opa334.Dopamine', 'the signer sets the identifier')
            self.assertEqual(libraries(archive.read(app + 'Dopamine')), [embed.LIBRARY])
            self.assertEqual(archive.getinfo(app + 'Dopamine').external_attr >> 16 & 0o777, 0o755)
            self.assertEqual(archive.read(app + 'Frameworks/ResizeAccess.dylib'), b'\xcf\xfa\xed\xfe library')
            self.assertEqual(archive.read(app + 'resize-helper.payload'), b'RESIZE-APFS-HELPER\nhelper')
            self.assertEqual(archive.read(app + 'Fonts/Mono.ttf'), b'font')
            self.assertEqual(archive.read(app + 'basebin.tar'), b'basebin')
            self.assertEqual(archive.read(app + 'Assets.car'), b'their images', "Dopamine's code draws from its images")
            self.assertEqual(info['CFBundleIcons'], {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60']}},
                             'by name, the icon would be Dopamine\'s')

    def test_dopamines_launch_screen_is_replaced_where_ios_looks_first(self):
        with self.prepared() as archive:
            self.assertEqual(archive.read('Payload/Dopamine.app/Base.lproj/LaunchScreen.storyboardc/Info.plist'), b'ours')
            self.assertEqual(archive.read('Payload/Dopamine.app/LaunchScreen.storyboardc/Info.plist'), b'ours')

    def test_the_helper_is_not_a_program_to_a_signer(self):
        # xcode_signing.sign_order signs every file that starts like a program.
        self.assertFalse((self.payload / 'Resources/resize-helper.payload').read_bytes()[:4] in
                         {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'})

    def test_build_and_app_agree_on_what_precedes_the_helper(self):
        build = (ROOT / 'scripts/build-device.sh').read_text()
        app = (ROOT / 'App/StorageAccess.swift').read_text()
        self.assertIn(r"printf 'RESIZE-APFS-HELPER\n'", build)
        self.assertIn(r'Data("RESIZE-APFS-HELPER\n".utf8)', app)

    def test_an_ipa_with_a_path_outside_itself_is_refused(self):
        with zipfile.ZipFile(self.root / 'bad.ipa', 'w') as archive:
            archive.writestr('../escape', b'x')
        with self.assertRaisesRegex(ValueError, 'Unsafe path'):
            embed.prepared_ipa(self.root / 'bad.ipa', self.root / 'work2', self.payload)


if __name__ == '__main__':
    unittest.main()
