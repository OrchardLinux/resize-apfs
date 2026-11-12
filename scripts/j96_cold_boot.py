"""Boot a prepared overlay on the iPad mini 4 (J96) with the cold-start DFU procedure.

On J96 (A8, iOS 15) palera1n only reaches Pongo reliably from a real power-off and
cool-down, so this wraps the external J96 cold-start tooling (cold-probe.py and its
live-probe.py) around palera1n 3.0.0 beta 3. Without --boot it checks local files
only. --boot performs one attempt with no automatic retry. A write-enabled overlay
additionally needs --allow-write; resizing still requires confirmation in the app.

Example:
  python3 scripts/j96_cold_boot.py --overlay out/j96-write.dmg \\
      --palera1n ~/Projects/j96-pongo-probe-20261030/palera1n-beta3 \\
      --cold-probe ~/Projects/j96-pongo-probe-20261030/cold-probe.py --allow-write --boot
"""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import shlex
import subprocess
import tempfile
import threading

from boot_device import command as validated_command
from image_format import require
from palera import discover

MINIMUM_COOL_DOWN = 60
RECOVERY_PIDS = range(0x1280, 0x1284)


def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def verify(overlay, palera1n, cold_probe, allow_write=False, cold_probe_sha256=None):
    """Check every local input; returns (command, manifest). Never touches a device."""
    overlay = pathlib.Path(overlay).resolve()
    cold_probe = pathlib.Path(cold_probe).resolve()
    require(cold_probe.is_file() and not cold_probe.is_symlink(), f'Missing cold-start script: {cold_probe}')
    require((cold_probe.parent / 'live-probe.py').is_file(), 'live-probe.py must sit next to cold-probe.py.')
    if cold_probe_sha256:
        require(sha256(cold_probe) == cold_probe_sha256, 'cold-probe.py changed since it was pinned.')
    info = discover(str(palera1n))
    # Overlay checksum and the palera1n boot payload (binpack) the overlay was prepared for.
    validated_command(overlay, info)
    manifest = json.loads(overlay.with_suffix('.json').read_text())
    require(manifest.get('bytes', overlay.stat().st_size) == overlay.stat().st_size, 'Overlay size mismatch.')
    # J96 is only proven with the exact palera1n executable the overlay was prepared with.
    require(manifest['palera1n'].get('installedBinarySHA256') == info['installedBinarySHA256'],
            'The overlay was prepared with a different palera1n executable.')
    require(manifest.get('deviceBuild', {}).get('minimumOS') == '15.0',
            'J96 runs iOS 15: prepare the overlay from the iOS 15 device build.')
    require(manifest.get('networkListenersEnabled') is False, 'Unexpected overlay network configuration.')
    mode = manifest.get('mode')
    require(mode in ('inspect', 'write'), f'Unknown overlay mode: {mode!r}.')
    require(mode != 'write' or allow_write, 'This overlay enables resizing; add --allow-write to use it.')
    # The proven J96 invocation: clean environment, CLI, bundled Pongo, full iPadOS boot.
    argv = ['/usr/bin/sudo', '/usr/bin/env', '-i', 'PATH=/usr/bin:/bin', 'LANG=C',
            info['path'], '--cli', *info['rootlessArguments'], '--override-overlay', str(overlay),
            '-d', '-n']
    return argv, manifest


def load_cold_procedure(cold_probe):
    spec = importlib.util.spec_from_file_location('j96_cold_probe', cold_probe)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def refuse_recovery_mode():
    for node in pathlib.Path('/sys/bus/usb/devices').glob('*'):
        try:
            apple = (node / 'idVendor').read_text().strip() == '05ac'
            pid = int((node / 'idProduct').read_text().strip(), 16)
        except (FileNotFoundError, ValueError):
            continue
        require(not (apple and pid in RECOVERY_PIDS),
                'The iPad is in recovery. Exit recovery and shut down normally first.')


def run_once(cold, argv, run):
    with (run / 'palera1n.log').open('x') as log:
        master, slave = os.openpty()
        try:
            process = subprocess.Popen(argv, stdout=slave, stderr=slave)
        except BaseException:
            os.close(master)
            raise
        finally:
            os.close(slave)
        reader = threading.Thread(target=cold.live.capture_terminal, args=(master, log), daemon=True)
        reader.start()
        try:
            return process.wait()
        except KeyboardInterrupt:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                print('The host tool is still running. Inspect this terminal before another attempt.', flush=True)
            raise
        finally:
            reader.join(timeout=5)


def boot(args, argv, manifest):
    cold = load_cold_procedure(args.cold_probe)
    refuse_recovery_mode()
    cursor = cold.kernel_cursor()
    preflight = cold.wait_power_off()
    require(preflight['power_off'] == 'slide', 'Use slide to power off, then rerun. No boot started.')
    cold.cool_down(args.cool_down)
    print('\nRefreshing sudo before the DFU button timer.', flush=True)
    subprocess.run(['/usr/bin/sudo', '-v'], check=True)
    device, _ = cold.guide_dfu_from_off()
    selected = cold.live.selected_dfu()
    require((selected['location'], selected['ecid']) == (device['location'], device['ecid']),
            'The selected device changed after DFU. No boot started.')
    verify(args.overlay, args.palera1n, args.cold_probe, args.allow_write, args.cold_probe_sha256)

    logs = args.logs or pathlib.Path(args.overlay).resolve().parent / 'logs'
    logs.mkdir(mode=0o700, parents=True, exist_ok=True)
    run = pathlib.Path(tempfile.mkdtemp(prefix=f"j96-{manifest['mode']}-", dir=logs))
    (run / 'attempt.json').write_text(json.dumps({
        'command': argv, 'coolDownSeconds': args.cool_down, 'mode': manifest['mode'],
        'overlaySHA256': manifest['sha256'], 'palera1n': manifest['palera1n'],
        'coldProbeSHA256': sha256(args.cold_probe)}, indent=2) + '\n')
    print(f"\nStarting one {manifest['mode']} boot. Keep the cable connected. Logs: {run}", flush=True)
    try:
        code = run_once(cold, argv, run)
        print('Host tool exit status:', code, flush=True)
        require(code == 0, 'The boot tool reported a failure. No automatic retry; keep the terminal output.')
    finally:
        try:
            (run / 'kernel.log').write_text(cold.kernel_log(cursor))
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print('Could not save the kernel log:', error, flush=True)
    print('\nWait for iPadOS, unlock the iPad and allow about a minute for Resize APFS to appear.')
    if manifest['mode'] == 'write':
        print('Check the minimum APFS size before reviewing a change, and wait for')
        print('"Completed and verified" before restarting after a resize.')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--overlay', type=pathlib.Path, required=True)
    parser.add_argument('--palera1n', default=os.environ.get('PALERA1N'),
                        help='palera1n executable the overlay was prepared with (default: $PALERA1N)')
    parser.add_argument('--cold-probe', type=pathlib.Path, required=True,
                        help='J96 cold-probe.py (live-probe.py must be next to it)')
    parser.add_argument('--cold-probe-sha256', help='refuse to run unless cold-probe.py has this hash')
    parser.add_argument('--allow-write', action='store_true', help='permit a write-enabled overlay')
    parser.add_argument('--cool-down', type=int, default=MINIMUM_COOL_DOWN, metavar='SECONDS')
    parser.add_argument('--logs', type=pathlib.Path, help='log directory (default: next to the overlay)')
    parser.add_argument('--boot', action='store_true', help='perform one cold-start boot')
    args = parser.parse_args()
    try:
        require(args.palera1n, 'Pass --palera1n or set PALERA1N.')
        require(args.cool_down >= MINIMUM_COOL_DOWN, 'Keep the iPad powered off for at least 60 seconds.')
        require(os.geteuid() != 0, 'Run as your normal user; only the USB boot tool uses sudo.')
        os.umask(0o077)
        argv, manifest = verify(args.overlay, args.palera1n, args.cold_probe,
                                args.allow_write, args.cold_probe_sha256)
        print(f"PASS: {manifest['mode']} overlay matches palera1n {manifest['palera1n'].get('version')}.")
        print('Boot command:', shlex.join(argv), flush=True)
        if not args.boot:
            print('Check complete. No device operation performed. Add --boot when ready.')
            return
        boot(args, argv, manifest)
    except KeyboardInterrupt:
        print('\nStopped. No automatic retry.', flush=True)
        raise SystemExit(130)
    except (OSError, ValueError, KeyError, ImportError, subprocess.SubprocessError) as error:
        parser.exit(1, f'STOP: {error}\n')


if __name__ == '__main__':
    main()
