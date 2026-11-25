"""The pinned palera1n, checkra1n and Dopamine, downloaded once into the shared Orchard cache.

The cache is the graphical installer's (orchard2): `~/Library/Caches/orchard2` on macOS,
`$XDG_CACHE_HOME/orchard2` or `~/.cache/orchard2` elsewhere. A release file is stored as
`files/sha256-<hash>`, exactly as the installer names it, so a file either one downloaded is
not downloaded again. Unpacked executables live under `tools/`. Every file is checked against
its pinned size and SHA-256 before it is used; nothing unverified is ever run.
"""
import hashlib
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

from image_format import require

PALERA1N_RELEASE = 'https://github.com/palera1n/palera1n/releases/download/v3.0.0-beta.4'
CHECKRA1N_RELEASE = 'https://assets.checkra.in/downloads'
DOPAMINE_RELEASE = 'https://github.com/opa334/Dopamine/releases/download/3.0.13'

# Kept identical to orchard2's crates/flow/src/assets.rs PALERA1N_PINS (v3.0.0-beta.4).
# (tool, os, arch) -> pin. `member` is the executable inside the package. `bundle` keeps the
# whole macOS app, because checkra1n loads a library from next to its executable.
PINS = {
    ('palera1n', 'macos', 'arm64'): dict(
        url=PALERA1N_RELEASE + '/palera1n-macos-universal.dmg', size=17_602_201,
        sha256='f61de50eea582c2647c55602c70251e8b20b867436a1a299a53a946f52bda296', package='dmg',
        member='palera1n.app/Contents/MacOS/palera1n',
        executable_sha256='b7e5d082e7bd5dbd03d47bc4ad7b1438a98d4cf4185c7f9599fa10df06f7020e'),
    ('palera1n', 'linux', 'arm64'): dict(
        url=PALERA1N_RELEASE + '/palera1n-linux-arm64.tar.gz', size=5_285_880,
        sha256='29f308fcfa5f2aa831b475fd9bba1318e4dc5de4ac4e2bc9516314b9232c56a0', package='tar.gz',
        member='bin/palera1n',
        executable_sha256='edf1f4a98865c4326d71b3ed975cd050076082c0da4787bce4ea535c7c8d9b2b'),
    ('palera1n', 'linux', 'x86_64'): dict(
        url=PALERA1N_RELEASE + '/palera1n-linux-x86_64.tar.gz', size=5_345_769,
        sha256='eb636e5f84c49804a4d34f6d2a7be22210aaaaefeaf6a463345644e60e26b084', package='tar.gz',
        member='bin/palera1n',
        executable_sha256='6aac0aee825cea96656d8d873944065a7b6ab89b5fa97582b8d0d5c23a14f1b9'),
    # checkra1n 0.12.4 beta, the last release (iOS 12.0-14.8.1). Its download URLs carry the
    # file's SHA-256. The macOS build is x86_64 only and runs under Rosetta on Apple silicon.
    ('checkra1n', 'macos', 'arm64'): dict(
        url=CHECKRA1N_RELEASE + '/macos/754bb6ec4747b2e700f01307315da8c9c32c8b5816d0fe1e91d1bdfc298fe07b/'
        'checkra1n%20beta%200.12.4.dmg', size=7_408_832,
        sha256='754bb6ec4747b2e700f01307315da8c9c32c8b5816d0fe1e91d1bdfc298fe07b', package='dmg',
        member='checkra1n.app/Contents/MacOS/checkra1n', bundle=True,
        executable_sha256='97aa3bdf24d54d071422e10b070502a2a36fc5b519cb5e728c512c1f2fda53b8'),
    ('checkra1n', 'linux', 'arm64'): dict(
        url=CHECKRA1N_RELEASE + '/linux/cli/arm64/43019a573ab1c866fe88edb1f2dd5bb38b0caf135533ee0d6e3ed720256b89d0/checkra1n',
        size=10_659_208, sha256='43019a573ab1c866fe88edb1f2dd5bb38b0caf135533ee0d6e3ed720256b89d0',
        package='executable', member=None, executable_sha256=None),
    ('checkra1n', 'linux', 'x86_64'): dict(
        url=CHECKRA1N_RELEASE + '/linux/cli/x86_64/dac9968939ea6e6bfbdedeb41d7e2579c4711dc2c5083f91dced66ca397dc51d/checkra1n',
        size=10_360_264, sha256='dac9968939ea6e6bfbdedeb41d7e2579c4711dc2c5083f91dced66ca397dc51d',
        package='executable', member=None, executable_sha256=None),
}
# Dopamine 3.0.13, the jailbreak app for the route without DFU. Installed on the device, not
# run here, so one file serves every computer. It is ad-hoc signed: the user signs it for
# sideloading (dopamine_route.py).
DOPAMINE = dict(url=DOPAMINE_RELEASE + '/Dopamine.ipa', size=55_422_988,
                sha256='3664edd737cc672af5d9036d2d1513fb1d50784f0c0cfd49cc6e651b8c665e14', package='file',
                member=None, executable_sha256=None)
for _system in ('macos', 'linux'):
    for _arch in ('arm64', 'x86_64'):
        PINS[('dopamine', _system, _arch)] = DOPAMINE
PINS[('palera1n', 'macos', 'x86_64')] = PINS[('palera1n', 'macos', 'arm64')]
PINS[('checkra1n', 'macos', 'x86_64')] = PINS[('checkra1n', 'macos', 'arm64')]

OVERRIDES = {'palera1n': 'PALERA1N', 'checkra1n': 'CHECKRA1N', 'dopamine': 'DOPAMINE'}


def host():
    system = 'macos' if sys.platform == 'darwin' else 'linux' if sys.platform.startswith('linux') else None
    arch = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'x86_64', 'amd64': 'x86_64'}.get(platform.machine().lower())
    require(system and arch, f'Unsupported computer: {sys.platform} {platform.machine()}. Use macOS or Linux on x86_64 or arm64.')
    return system, arch


def cache_root():
    if os.environ.get('ORCHARD_CACHE'):
        return pathlib.Path(os.environ['ORCHARD_CACHE'])
    home = pathlib.Path.home()
    if sys.platform == 'darwin':
        return home / 'Library/Caches/orchard2'
    xdg = os.environ.get('XDG_CACHE_HOME')
    return (pathlib.Path(xdg) if xdg and os.path.isabs(xdg) else home / '.cache') / 'orchard2'


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def package_path(pin, root=None, fetch=None):
    """The verified release file in the cache, downloaded first when missing or damaged."""
    files = (root or cache_root()) / 'files'
    files.mkdir(parents=True, exist_ok=True)
    path = files / ('sha256-' + pin['sha256'])
    if path.is_file() and path.stat().st_size == pin['size'] and sha256_file(path) == pin['sha256']:
        return path
    name = pin['url'].rsplit('/', 1)[-1].replace('%20', ' ')
    print(f'Downloading {name} ({pin["size"] / 1e6:.1f} MB)...', flush=True)
    temporary = files / f'.sha256-{pin["sha256"]}.{os.getpid()}'
    try:
        (fetch or download)(pin['url'], temporary, pin['size'])
        require(temporary.stat().st_size == pin['size'], f'{name}: the download has the wrong size.')
        require(sha256_file(temporary) == pin['sha256'], f'{name}: the download does not match its pinned checksum.')
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    return path


def download(url, destination, size):
    request = urllib.request.Request(url, headers={'User-Agent': 'resize-apfs'})
    with urllib.request.urlopen(request, timeout=60) as response, open(destination, 'wb') as out:
        received = 0
        while True:
            block = response.read(1 << 20)
            if not block:
                break
            received += len(block)
            require(received <= size, 'The download is larger than expected.')
            out.write(block)


def unpack(package, pin, destination):
    """Put the pinned executable (or app bundle) at `destination`."""
    work = pathlib.Path(tempfile.mkdtemp(prefix='.unpack-', dir=destination.parent))
    try:
        if pin['package'] == 'executable':
            target = work / 'tool'
            shutil.copyfile(package, target)
        elif pin['package'] == 'tar.gz':
            target = work / 'tool'
            with tarfile.open(package) as archive:
                member = archive.getmember(pin['member'])
                require(member.isfile(), 'The archive does not hold the expected executable.')
                with archive.extractfile(member) as source, open(target, 'wb') as out:
                    shutil.copyfileobj(source, out)
        else:
            app = pin['member'].split('/', 1)[0]
            target = work / (app if pin.get('bundle') else 'tool')
            mount = work / 'mount'
            mount.mkdir()
            subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noverify', '-noautoopen',
                            '-mountpoint', str(mount), str(package)], check=True, capture_output=True, timeout=120)
            try:
                source = mount / (app if pin.get('bundle') else pin['member'])
                subprocess.run(['ditto', str(source), str(target)], check=True, capture_output=True, timeout=120)
            finally:
                subprocess.run(['hdiutil', 'detach', str(mount)], capture_output=True, timeout=60)
        executable = work / pin['member'] if pin.get('bundle') else target
        expected = pin['executable_sha256'] or pin['sha256']
        require(sha256_file(executable) == expected, 'The unpacked executable does not match its pinned checksum.')
        executable.chmod(0o755)
        os.replace(target, destination)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def provide(tool, root=None, fetch=None):
    """The path of the pinned tool's executable, ready to run; for Dopamine, its verified IPA.

    `PALERA1N` / `CHECKRA1N` / `DOPAMINE` point to a developer's own build instead and skip the download.
    """
    override = os.environ.get(OVERRIDES[tool])
    if override:
        path = pathlib.Path(shutil.which(override) or override)
        require(path.is_file(), f'{OVERRIDES[tool]} does not point to a file: {override}')
        return path.resolve()
    pin = PINS.get((tool, *host()))
    require(pin is not None, f'{tool} has no release for this computer.')
    root = root or cache_root()
    if pin['package'] == 'file':
        return package_path(pin, root, fetch)
    tools = root / 'tools'
    tools.mkdir(parents=True, exist_ok=True)
    key = pin['sha256'][:16]  # orchard2 names its unpacked palera1n the same way
    if pin.get('bundle'):
        bundle = tools / f'{tool}-{key}.app'
        executable = bundle / pin['member'].split('/', 1)[1]
    else:
        bundle = executable = tools / f'{tool}-{key}'
    expected = pin['executable_sha256'] or pin['sha256']
    if executable.is_file() and sha256_file(executable) == expected:
        return executable
    if bundle.exists():
        shutil.rmtree(bundle) if bundle.is_dir() else bundle.unlink()
    unpack(package_path(pin, root, fetch), pin, bundle)
    return executable
