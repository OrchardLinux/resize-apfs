"""A stand-in Dopamine IPA and Resize APFS payload for the tests of the route without DFU."""
import pathlib
import plistlib
import struct
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))

import embed  # noqa: E402


def macho(names=embed.INTERFACE + (embed.SETTING,), room=256):
    """A 64-bit Mach-O with one section holding `names`, `room` unused bytes before it."""
    content = b'\0' + b''.join(name.encode() + b'\0' for name in names)
    commands = 72 + 80
    start = embed.HEADER + commands + room
    segment = struct.pack('<II16sQQQQIIII', embed.LC_SEGMENT_64, commands, b'__TEXT', 0, 0x4000, 0, start + len(content), 5, 5, 1, 0)
    section = struct.pack('<16s16sQQIIIIIIII', b'__objc_methname', b'__TEXT', start, len(content), start, 0, 0, 0, 0, 0, 0, 0)
    header = struct.pack('<IiiIIIII', embed.MH_MAGIC_64, 0x0100000c, 0, 2, 1, commands, 0, 0)
    return header + segment + section + b'\0' * room + content


def make_ipa(path, executable=None):
    info = {'CFBundleExecutable': 'Dopamine', 'CFBundleIdentifier': 'com.opa334.Dopamine', 'CFBundleDisplayName': 'Dopamine',
            'UILaunchStoryboardName': 'LaunchScreen', 'NSPhotoLibraryUsageDescription': 'Dopamine needs photos',
            embed.SCENES: {'UISceneConfigurations': {}}}
    with zipfile.ZipFile(path, 'w') as archive:
        member = zipfile.ZipInfo('Payload/Dopamine.app/Dopamine')
        member.external_attr = 0o755 << 16
        archive.writestr(member, macho() if executable is None else executable)
        archive.writestr('Payload/Dopamine.app/Info.plist', plistlib.dumps(info))
        archive.writestr('Payload/Dopamine.app/Base.lproj/LaunchScreen.storyboardc/Info.plist', b'theirs')
        archive.writestr('Payload/Dopamine.app/basebin.tar', b'basebin')
        archive.writestr('Payload/Dopamine.app/Assets.car', b'their images')
    return path


def make_payload(folder):
    folder = pathlib.Path(folder)
    (folder / 'Resources/LaunchScreen.storyboardc').mkdir(parents=True)
    (folder / 'Resources/Fonts').mkdir()
    (folder / 'ResizeAccess.dylib').write_bytes(b'\xcf\xfa\xed\xfe library')
    (folder / 'Resources/LaunchScreen.storyboardc/Info.plist').write_bytes(b'ours')
    (folder / 'Resources/Fonts/Mono.ttf').write_bytes(b'font')
    (folder / 'Resources/resize-helper.payload').write_bytes(b'RESIZE-APFS-HELPER\nhelper')
    (folder / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleDisplayName': 'Resize APFS', 'CFBundleName': 'ResizeAPFS', 'UILaunchStoryboardName': 'LaunchScreen',
        'UIAppFonts': ['Fonts/Mono.ttf'], 'CFBundleIdentifier': 'dev.omarchy.resize-apfs', 'OrchardSystem': 'Omarchy A',
        'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60'], 'CFBundleIconName': 'AppIcon'}}}))
    return folder
