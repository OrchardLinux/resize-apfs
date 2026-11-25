"""Release launcher for macOS and Linux."""
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import platform
import subprocess
import sys

import boot_run
import tools as pinned
from boot_device import command
from image_format import require
from palera import discover

ROOT = pathlib.Path(__file__).resolve().parents[1]


def verify_package():
    sums = ROOT / 'SHA256SUMS'
    require(sums.is_file(), 'Use the release ZIP. Developers: build and package the project first.')
    for line in sums.read_text().splitlines():
        digest, name = line.split('  ', 1)
        path = ROOT / name
        require(not path.is_symlink() and path.resolve().is_relative_to(ROOT), 'Unsafe package path.')
        require(hashlib.sha256(path.read_bytes()).hexdigest() == digest, 'Package checksum mismatch: ' + name)
    return sums.read_bytes()


def made_by(overlay, info):
    """True when the overlay was built from this palera1n."""
    try:
        manifest = json.loads(overlay.with_suffix('.json').read_text())
        return manifest['palera1n']['installedBinarySHA256'] == info['installedBinarySHA256']
    except (OSError, ValueError, KeyError, TypeError):
        return False


def route(given, dopamine=False):
    """'palera1n', 'checkra1n' or 'dopamine': --dopamine, --ios, or the user's answer."""
    if dopamine:
        require(given is None or given >= 15, 'The Dopamine route needs iOS/iPadOS 15 or later.')
        return 'dopamine'
    if given is None:
        print('iOS/iPadOS version on the device (Settings > General > About):\n'
              '  1) 15 or later\n'
              '  2) 12, 13 or 14\n'
              '  3) 15 or later, without DFU: Dopamine (also iPhone XS, XR, 11 and other A12/A13 devices)')
        answer = input('> ').strip()
        require(answer in ('1', '2', '3'), 'Please answer 1, 2 or 3.')
        return {'1': 'palera1n', '2': 'checkra1n', '3': 'dopamine'}[answer]
    require(given >= 12, 'Resize APFS needs iOS/iPadOS 12 or later.')
    return 'palera1n' if given >= 15 else 'checkra1n'


def main():
    parser = argparse.ArgumentParser(description='Prepare and boot Resize APFS: palera1n for iOS 15+, checkra1n for iOS 12-14, '
                                     'Dopamine for iOS 15+ without DFU.')
    parser.add_argument('action', choices=['prepare', 'boot'])
    parser.add_argument('--ios', type=int, metavar='VERSION',
                        help='the installed iOS major version (e.g. 15 or 12); skips the question')
    parser.add_argument('--dopamine', action='store_true',
                        help='use Dopamine instead of DFU (iOS 15 or later); skips the question')
    args = parser.parse_args()
    require(sys.version_info >= (3, 9), 'Python 3.9 or later is required.')
    require(sys.platform == 'darwin' or sys.platform.startswith('linux'), 'Use Linux or macOS to prepare the overlay.')
    payload = verify_package()
    chosen = route(args.ios, args.dopamine)
    if chosen == 'dopamine':
        import dopamine_route
        ipa = pinned.provide('dopamine')
        if args.action == 'boot':
            dopamine_route.run(ipa)
        return
    if chosen == 'checkra1n':
        import checkra1n_route
        checkra1n_route.payload()
        executable = pinned.provide('checkra1n')
        if args.action == 'boot':
            checkra1n_route.run(executable)
        return
    palera1n = pinned.provide('palera1n')
    os.environ.setdefault('RA1N_CLI', '1')  # palera1n 3.0 starts its terminal interface only when asked
    info = discover(str(palera1n))
    if sys.platform.startswith('linux'):
        from overlay_linux import tools
        tools()
    work = ROOT / '.work'
    work.mkdir(exist_ok=True, mode=0o700)
    with (work / 'prepare.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another overlay preparation is running in this folder.')
        # A universal executable can contain different payloads for each host CPU.
        key = hashlib.sha256(payload + info['installedBinarySHA256'].encode() +
                             sys.platform.encode() + platform.machine().encode()).hexdigest()[:20]
        overlay = work / ('release-' + key + '.dmg')
        log = work / 'prepare.log'
        if overlay.is_file() and not made_by(overlay, info):
            overlay.unlink()
        if not overlay.is_file():
            print('Preparing the boot files...', flush=True)
        with log.open('w') as stream:
            if not overlay.is_file():
                result = subprocess.run([sys.executable, str(ROOT / 'scripts/build-overlay.py'), '--enable-writes', '--palera1n', str(palera1n), '--output', str(overlay)],
                                        cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
            else:
                result = subprocess.run([sys.executable, str(ROOT / 'scripts/audit-overlay.py'), str(overlay)],
                                        cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        require(result.returncode == 0, 'Overlay preparation failed. Details: ' + str(log))
    if args.action == 'prepare':
        return
    boot_run.run(command(overlay, discover(str(palera1n))), work / 'palera1n.log')
    print('Done. Unlock the device: Resize APFS appears on the Home Screen within a minute.')


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit('\nCancelled.')
    except (ValueError, OSError, KeyError, subprocess.SubprocessError, EOFError) as error:
        raise SystemExit(str(error))
