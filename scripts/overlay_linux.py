"""Unprivileged Linux overlay construction and readback."""
import hashlib
import os
import pathlib
import platform
import plistlib
import secrets
import stat
import struct
import subprocess
import tempfile
import uuid

from image_format import HFSImage, read_udif, require

ROOT = pathlib.Path(__file__).resolve().parents[1]


def tools():
    arch = {'aarch64': 'arm64', 'arm64': 'arm64', 'x86_64': 'x86_64'}.get(platform.machine())
    require(arch is not None, 'Linux preparation supports x86_64 and arm64.')
    candidates = [ROOT / 'tools' / ('linux-' + arch), ROOT / 'out/host-tools' / ('linux-' + arch)]
    if os.environ.get('RESIZE_APFS_HOST_TOOLS'):
        candidates.insert(0, pathlib.Path(os.environ['RESIZE_APFS_HOST_TOOLS']))
    for directory in candidates:
        if all((directory / name).is_file() and os.access(directory / name, os.X_OK) for name in ('hfsplus', 'dmg')):
            return directory
    raise ValueError('Linux image tools are missing. Use the complete release ZIP; developers can run scripts/build-linux-tools.sh.')


def normalize(raw):
    data = raw.read_bytes()
    image = HFSImage(data)
    block = image.block
    bitmap = image.fork(image.header[112:192])
    total = len(data) // block
    require(len(bitmap) * 8 >= total, 'Incomplete HFS allocation bitmap.')
    with raw.open('r+b') as stream:
        zero = bytes(block)
        for n in range(total):
            if not bitmap[n // 8] & (1 << (7 - n % 8)):
                stream.seek(n * block)
                stream.write(zero)
        identity = secrets.token_bytes(8)
        for offset in (1024, len(data) - 1024):
            stream.seek(offset)
            require(stream.read(2) == image.header[:2], 'Invalid backup volume header.')
            stream.seek(offset + 104)
            stream.write(identity)


def compress(directory, raw, output):
    subprocess.run([str(directory / 'dmg'), 'dmg', str(raw), str(output)], check=True)
    with output.open('r+b') as stream:
        stream.seek(-512, 2)
        footer = stream.read(512)
        require(footer[:4] == b'koly' and struct.unpack_from('>Q', footer, 492)[0] > 0, 'Invalid generated DMG size.')
        stream.seek(output.stat().st_size - 512 + 64)
        stream.write(uuid.uuid4().bytes)
    decoded, _ = read_udif(output)
    require(decoded == raw.read_bytes(), 'Generated DMG failed round-trip verification.')


def build(base, destination, writes):
    directory = tools()
    data, _ = read_udif(base)
    original = HFSImage(data)
    require('/Library/LaunchDaemons/palera1nd.plist' in original.entries and '/loader.dmg' in original.entries,
            'Unsupported palera1n overlay layout.')
    device = ROOT / 'out/device'
    with tempfile.TemporaryDirectory(prefix='overlay-linux-', dir=ROOT / '.work') as temporary:
        scratch = pathlib.Path(temporary)
        outer, loader = scratch / 'outer.raw', scratch / 'loader.raw'
        outer.write_bytes(data)
        loader.write_bytes(data)
        def h(image, *args):
            require(image.is_file() and not image.is_symlink(), 'Expected a regular build image.')
            subprocess.run([str(directory / 'hfsplus'), str(image), *map(str, args)], check=True)
        def add(image, target, source):
            h(image, 'add', source, target)
        def put(image, target, value):
            file = scratch / 'config.plist'
            file.write_bytes(plistlib.dumps(value))
            add(image, target, file)
        def grow(image, minimum):
            size = (max(minimum, image.stat().st_size) + 1048575) // 1048576 * 1048576
            require(size <= 256 * 1024 * 1024, 'Overlay exceeds the supported build size.')
            if size > image.stat().st_size:
                h(image, 'grow', size)
        app = device / 'ResizeAPFS.app'
        require(not any(p.is_symlink() for p in app.rglob('*')), 'App bundle symlinks need a newer image backend.')
        app_bytes = sum(p.stat().st_size for p in app.rglob('*') if p.is_file())
        grow(loader, app_bytes * 2 + 4 * 1048576)
        h(loader, 'rmall', '/')
        h(loader, 'mkdir', '/palera1nLoader.app')
        h(loader, 'addall', app, '/palera1nLoader.app')
        h(loader, 'chmod', '0755', '/palera1nLoader.app/ResizeAPFS')
        normalize(loader)
        nested = scratch / 'loader.dmg'
        compress(directory, loader, nested)
        grow(outer, max(32 * 1048576, len(data) + nested.stat().st_size + 6 * 1048576))
        add(outer, '/loader.dmg', nested)
        if '/tvloader.dmg' in original.entries:
            h(outer, 'rm', '/tvloader.dmg')
        for name in ('resize-helper', 'resize-overlay-entry'):
            add(outer, '/usr/libexec/' + name, device / name)
            h(outer, 'chmod', '0755', '/usr/libexec/' + name)
        config = plistlib.loads((ROOT / 'Device/dev.omarchy.resize-apfs.plist').read_bytes())
        if writes:
            config['ProgramArguments'].append('--allow-writes')
        put(outer, '/Library/LaunchDaemons/dev.omarchy.resize-apfs.plist', config)
        daemon = plistlib.loads(original.read('/Library/LaunchDaemons/palera1nd.plist'))
        daemon['Program'] = '/cores/binpack/usr/libexec/resize-overlay-entry'
        daemon['ProgramArguments'] = [daemon['Program']]
        daemon['RunAtLoad'] = True
        put(outer, '/Library/LaunchDaemons/palera1nd.plist', daemon)
        for path in original.entries:
            name = pathlib.PurePosixPath(path)
            if str(name.parent) == '/Library/LaunchDaemons' and name.name.startswith(('dropbear-', 'telnetd', 'debug-shell')) and name.suffix == '.plist':
                value = plistlib.loads(original.read(path))
                value['Disabled'] = True
                value.pop('Sockets', None)
                put(outer, path, value)
        normalize(outer)
        compress(directory, outer, destination)


def audit(image, manifest):
    raw, outer_id = read_udif(image)
    outer = HFSImage(raw)
    with tempfile.TemporaryDirectory(prefix='overlay-audit-', dir=ROOT / '.work') as temporary:
        nested = pathlib.Path(temporary) / 'loader.dmg'
        nested.write_bytes(outer.read('/loader.dmg'))
        raw, inner_id = read_udif(nested)
    inner = HFSImage(raw)
    require(any(outer_id) and any(inner_id) and outer_id != inner_id and
            any(outer.volume_id) and any(inner.volume_id) and outer.volume_id != inner.volume_id,
            'Missing or duplicate image identities.')
    require('/tvloader.dmg' not in outer.entries, 'Unexpected TV loader.')
    for path, entry in inner.entries.items():
        require(path in ('/', '/palera1nLoader.app', '/' + '\0' * 4 + 'HFS+PrivateDirectoryData', '/' + '\0' * 4 + 'HFS+ Private Data') or path.startswith('/palera1nLoader.app/'), 'Unexpected app-image contents.')
        require(entry['uid'] == entry['gid'] == 0, 'App image is not root-owned.')
    device = ROOT / 'out/device'
    for path in (device / 'ResizeAPFS.app').rglob('*'):
        if path.is_file():
            relative = path.relative_to(device / 'ResizeAPFS.app')
            require(inner.read('/palera1nLoader.app/' + str(relative)) == path.read_bytes(), 'App resource readback mismatch: ' + str(relative))
    app_path = '/palera1nLoader.app/ResizeAPFS'
    require(inner.entries[app_path]['mode'] & 0o111 != 0, 'App executable permission missing.')
    for name in ('resize-helper', 'resize-overlay-entry'):
        path = '/usr/libexec/' + name
        entry = outer.entries[path]
        require(entry['uid'] == entry['gid'] == 0 and entry['mode'] & 0o111 != 0, 'Invalid helper ownership or mode.')
        require(hashlib.sha256(outer.read(path)).hexdigest() == manifest['deviceBuild']['files'][name]['sha256'], 'Helper readback mismatch.')
    for path in ['/Library/LaunchDaemons/dev.omarchy.resize-apfs.plist', '/Library/LaunchDaemons/palera1nd.plist']:
        entry = outer.entries[path]
        require(entry['uid'] == entry['gid'] == 0 and entry['mode'] & 0o022 == 0, 'Invalid daemon ownership or mode.')
    daemon = plistlib.loads(outer.read('/Library/LaunchDaemons/dev.omarchy.resize-apfs.plist'))
    require(daemon['ProgramArguments'][0] == '/cores/binpack/usr/libexec/resize-helper', 'Invalid helper path.')
    require(('--allow-writes' in daemon['ProgramArguments']) == (manifest['mode'] == 'write'), 'Incorrect write permission.')
    require(daemon['KeepAlive'] and daemon['RunAtLoad'] and daemon['AbandonProcessGroup'], 'Invalid helper supervision.')
    wrapper = plistlib.loads(outer.read('/Library/LaunchDaemons/palera1nd.plist'))
    require(wrapper['Program'] == '/cores/binpack/usr/libexec/resize-overlay-entry' and wrapper['RunAtLoad'], 'Invalid boot hook.')
    require(outer.read('/usr/sbin/palera1nd') == b'../../../payload', 'Boot symlink target changed.')
    require(stat.S_ISLNK(outer.entries['/usr/sbin/palera1nd']['mode']), 'Boot symlink was replaced.')
    for path in outer.entries:
        name = pathlib.PurePosixPath(path)
        if str(name.parent) == '/Library/LaunchDaemons' and name.name.startswith(('dropbear-', 'telnetd', 'debug-shell')) and name.suffix == '.plist':
            value = plistlib.loads(outer.read(path))
            require(value.get('Disabled') is True and 'Sockets' not in value, 'Unexpected network listener.')
    print('PASS: overlay contents, ownership, configuration and payload readback verified.')
