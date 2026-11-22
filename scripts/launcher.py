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


def ios_version(given):
    """The installed iOS major version: --ios, or the user's answer. It picks the route."""
    if given is None:
        print('Which version of iOS/iPadOS is installed on the device?\n'
              '(On the device: Settings > General > About > iOS Version.)\n'
              '  1) iOS/iPadOS 15 or later\n'
              '  2) iOS/iPadOS 12, 13 or 14')
        answer = input('Type 1 or 2: ').strip()
        require(answer in ('1', '2'), 'Please answer 1 or 2.')
        given = 15 if answer == '1' else 12
    require(given >= 12, 'Resize APFS needs iOS/iPadOS 12 or later.')
    return given


def main():
    parser = argparse.ArgumentParser(description='Prepare and boot Resize APFS: palera1n for iOS 15+, checkra1n for iOS 12-14.')
    parser.add_argument('action', choices=['prepare', 'boot'])
    parser.add_argument('--ios', type=int, metavar='VERSION',
                        help='the installed iOS major version (e.g. 15 or 12); skips the question')
    args = parser.parse_args()
    require(sys.version_info >= (3, 9), 'Python 3.9 or later is required.')
    require(sys.platform == 'darwin' or sys.platform.startswith('linux'), 'Use Linux or macOS to prepare the overlay.')
    payload = verify_package()
    if ios_version(args.ios) < 15:
        import checkra1n_route
        checkra1n_route.payload()
        executable = pinned.provide('checkra1n')
        print('checkra1n ready.', flush=True)
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
        print('Preparing palera1n overlay...', flush=True)
        with log.open('w') as stream:
            if not overlay.is_file():
                result = subprocess.run([sys.executable, str(ROOT / 'scripts/build-overlay.py'), '--enable-writes', '--output', str(overlay)],
                                        cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
            else:
                result = subprocess.run([sys.executable, str(ROOT / 'scripts/audit-overlay.py'), str(overlay)],
                                        cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        require(result.returncode == 0, 'Overlay preparation failed. Details: ' + str(log))
        print('Overlay ready.', flush=True)
    if args.action == 'prepare':
        return
    print('\nBoot tips:\n  Before DFU: close browsers that may use WebUSB.\n  Chrome USB settings: chrome://settings/content/usbDevices\n  Stuck at the Apple logo after palera1n starts? Briefly disconnect\n  the cable from the device and reconnect it.\n\nAfter boot: wait for iOS/iPadOS to start normally, then unlock the device.\nThe Resize APFS icon can take about a minute to appear on the Home Screen.\n\nBack up first. Resizing still requires confirmation in the app.\nConnect only the intended device and follow palera1n’s DFU instructions.')
    if input('Start palera1n now? Type yes: ').strip() != 'yes':
        print('Boot cancelled. Nothing was sent to the device.')
        return
    # Recheck the external installation after the prompt; never reuse stale argv.
    argv = command(overlay, discover(str(palera1n)))
    print('Starting palera1n...', flush=True)
    os.execv(argv[0], argv)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit('\nCancelled.')
    except (ValueError, OSError, KeyError, subprocess.SubprocessError, EOFError) as error:
        raise SystemExit(str(error))
