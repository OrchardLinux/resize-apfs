"""Resize APFS inside the pinned Dopamine app: one app for the route without DFU.

The official Dopamine release (tools.py pins it by size and SHA-256) stays as it is, except:

- its executable gets one more library to load, `Frameworks/ResizeAccess.dylib`: the Resize
  APFS interface plus the few calls into Dopamine it makes (Access/DopamineInterface.h);
- Info.plist loses Dopamine's scene configuration, so Dopamine's own interface never appears,
  and takes the name, icon, launch screen and fonts of Resize APFS;
- the Resize APFS resources and the storage helper (`resize-helper.payload`) are added.

Nothing of Dopamine is rebuilt or removed. Everything here runs on the user's computer, on
Linux and macOS, before the app is signed with the user's Apple ID (sideload.py).
"""
import pathlib
import plistlib
import shutil
import struct
import zipfile

from image_format import require

LIBRARY = '@executable_path/Frameworks/ResizeAccess.dylib'
# What Access/AccessBridge.m calls in Dopamine, as Access/DopamineInterface.h declares it.
# A Dopamine release without one of these names is refused instead of failing on the device.
INTERFACE = ('DOJailbreaker', 'contiguousMappingWorkaroundNeeded', 'applyContiguousMappingWorkaround',
             'runWithError:didRemoveJailbreak:showLogs:', 'finalize',
             'DOEnvironmentManager', 'sharedManager', 'isJailbroken', 'runAsRoot:', 'runUnsandboxed:')
# Taken from the Resize APFS Info.plist; a key it lacks is removed.
INFO_KEYS = ('CFBundleDisplayName', 'CFBundleName', 'CFBundleShortVersionString', 'CFBundleVersion',
             'CFBundleIcons', 'CFBundleIcons~ipad', 'CFBundleIconFiles', 'UILaunchStoryboardName', 'UIAppFonts',
             'UIStatusBarStyle', 'UISupportedInterfaceOrientations', 'UISupportedInterfaceOrientations~ipad',
             'UISupportedInterfaceOrientations~iphone', 'NSPhotoLibraryUsageDescription')
SCENES = 'UIApplicationSceneManifest'

MH_MAGIC_64 = 0xfeedfacf
FAT_MAGIC = 0xcafebabe
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xc
HEADER = 32


def check_interface(executable):
    """Refuse a Dopamine executable that lacks something Resize APFS calls."""
    missing = [name for name in INTERFACE if name.encode() + b'\0' not in executable]
    require(not missing, 'This Dopamine release does not fit this Resize APFS: it has no ' + ', '.join(missing) + '.')


def load_command(path):
    name = path.encode() + b'\0'
    name += b'\0' * (-(24 + len(name)) % 8)
    # name offset, timestamp, current version 1.0.0, compatibility version 1.0.0
    return struct.pack('<IIIIII', LC_LOAD_DYLIB, 24 + len(name), 24, 2, 0x10000, 0x10000) + name


def add_to_slice(data, path):
    """A 64-bit Mach-O with `path` added to the libraries it loads, in the unused space
    between its load commands and its first section. Its size and offsets stay the same."""
    magic, _, _, _, count, size, _, _ = struct.unpack_from('<IiiIIIII', data)
    require(magic == MH_MAGIC_64, 'The Dopamine executable is not a 64-bit program.')
    first_section = len(data)
    offset = HEADER
    for _ in range(count):
        command, length = struct.unpack_from('<II', data, offset)
        require(length >= 8 and offset + length <= HEADER + size, 'The Dopamine executable has damaged load commands.')
        if command == LC_LOAD_DYLIB:
            start = offset + struct.unpack_from('<I', data, offset + 8)[0]
            if data[start:offset + length].split(b'\0', 1)[0] == path.encode():
                return data
        if command == LC_SEGMENT_64:
            sections = struct.unpack_from('<I', data, offset + 64)[0]
            for index in range(sections):
                file_offset = struct.unpack_from('<I', data, offset + 72 + index * 80 + 48)[0]
                if file_offset:
                    first_section = min(first_section, file_offset)
        offset += length
    added = load_command(path)
    end = HEADER + size
    require(end + len(added) <= first_section and not any(data[end:end + len(added)]),
            'The Dopamine executable has no room for another library.')
    return (data[:16] + struct.pack('<II', count + 1, size + len(added)) + data[24:end] + added +
            data[end + len(added):])


def add_library(data, path=LIBRARY):
    """`data` (a Mach-O executable, one or several architectures) loading `path` too."""
    if struct.unpack_from('>I', data)[0] != FAT_MAGIC:
        return add_to_slice(data, path)
    result = bytearray(data)
    for index in range(struct.unpack_from('>I', data, 4)[0]):
        offset, size = struct.unpack_from('>II', data, 8 + index * 20 + 8)
        result[offset:offset + size] = add_to_slice(data[offset:offset + size], path)
    return bytes(result)


def unpack(ipa, folder):
    """The one app in `ipa`, unpacked under `folder`, and each archive member's mode."""
    folder = pathlib.Path(folder)
    with zipfile.ZipFile(ipa) as archive:
        for info in archive.infolist():
            require((folder / info.filename).resolve().is_relative_to(folder.resolve()), 'Unsafe path in the Dopamine IPA.')
        archive.extractall(folder)
        modes = {info.filename: info.external_attr >> 16 for info in archive.infolist()}
    apps = list((folder / 'Payload').glob('*.app'))
    require(len(apps) == 1, 'The Dopamine IPA does not hold exactly one app.')
    return apps[0], modes


def pack(folder, output, modes):
    folder = pathlib.Path(folder)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(folder.rglob('*')):
            name = path.relative_to(folder).as_posix() + ('/' if path.is_dir() else '')
            info = zipfile.ZipInfo.from_file(path, name)
            # Keep the original modes: executables must stay executable after signing.
            info.external_attr = (modes.get(name) or (0o755 if path.is_dir() else 0o644)) << 16
            if path.is_dir():
                archive.writestr(info, b'')
            else:
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, path.read_bytes())
    return output


def merge(app, payload):
    """Put Resize APFS (`payload`: out/device/access) into the unpacked Dopamine `app`."""
    app, payload = pathlib.Path(app), pathlib.Path(payload)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    ours = plistlib.loads((payload / 'Info.plist').read_bytes())
    executable = app / info['CFBundleExecutable']
    data = executable.read_bytes()
    check_interface(data)
    executable.write_bytes(add_library(data))
    (app / 'Frameworks').mkdir(exist_ok=True)
    shutil.copyfile(payload / 'ResizeAccess.dylib', app / 'Frameworks/ResizeAccess.dylib')
    shutil.copytree(payload / 'Resources', app, dirs_exist_ok=True)
    # Dopamine keeps its launch screen in a language folder, which iOS would prefer to ours.
    launch = ours.get('UILaunchStoryboardName', '') + '.storyboardc'
    for theirs in app.glob('*.lproj/' + launch):
        shutil.rmtree(theirs)
        shutil.copytree(payload / 'Resources' / launch, theirs)
    info.pop(SCENES, None)
    for key in INFO_KEYS:
        if key in ours:
            info[key] = ours[key]
        else:
            info.pop(key, None)
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))


def prepared_ipa(ipa, work, payload):
    """`work`/ResizeAPFS.ipa: the Dopamine `ipa` with Resize APFS in it, ready to be signed."""
    work = pathlib.Path(work)
    app, modes = unpack(ipa, work / 'unpacked')
    merge(app, payload)
    return pack(work / 'unpacked', work / 'ResizeAPFS.ipa', modes)
