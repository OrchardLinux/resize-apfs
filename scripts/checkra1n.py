"""Host entry path for checkra1n (iOS 12-14 rootful SSH) devices."""
import hashlib
import os
import pathlib
import shlex
import shutil
import subprocess

from image_format import require

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_REMOTE_PATH = '/var/root/resize-helper-ios12'


def discover_checkra1n(selected=None):
    """Locate an installed checkra1n executable without running it."""
    candidates = [
        selected,
        os.environ.get('CHECKRA1N'),
        shutil.which('checkra1n'),
        '/Applications/checkra1n.app/Contents/MacOS/checkra1n',
    ]
    for candidate in candidates:
        if not candidate:
            continue
        resolved = shutil.which(candidate) or candidate
        path = pathlib.Path(resolved)
        if path.is_file() and os.access(path, os.X_OK):
            return {'path': str(path.resolve()),
                    'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    return None


def helper_binary(root=ROOT):
    """Return the prebuilt iOS 12 checkra1n helper binary and its sha256."""
    binary = pathlib.Path(root) / 'out/device/resize-helper-ios12'
    require(binary.is_file(),
            'iOS 12 helper not found at out/device/resize-helper-ios12. Build it with ./scripts/build-device.sh --ios12-only.')
    return {'path': str(binary),
            'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'bytes': binary.stat().st_size}


def ssh_base(host, port=22, identity=None):
    cmd = ['ssh', '-p', str(port)]
    if identity:
        cmd += ['-i', str(identity), '-o', 'IdentitiesOnly=yes']
    cmd.append(host)
    return cmd


def scp_command(local_path, host, remote_path=DEFAULT_REMOTE_PATH, port=22, identity=None):
    cmd = ['scp', '-P', str(port)]
    if identity:
        cmd += ['-i', str(identity), '-o', 'IdentitiesOnly=yes']
    cmd += [str(local_path), f'{host}:{remote_path}']
    return cmd


def remote_helper_command(host, helper_args, remote_path=DEFAULT_REMOTE_PATH, port=22, identity=None):
    quoted = ' '.join(shlex.quote(arg) for arg in [remote_path] + list(helper_args))
    return ssh_base(host, port=port, identity=identity) + [quoted]


def run_checkra1n_action(args, root=ROOT):
    helper = helper_binary(root)
    if args.checkra1n_action == 'info':
        binary = discover_checkra1n()
        print('iOS 12-14 / checkra1n (rootful SSH) helper:')
        print(f"  Helper binary : {helper['path']} ({helper['bytes']} bytes)")
        print(f"  Helper sha256 : {helper['sha256']}")
        print(f"  checkra1n CLI : {binary['path'] if binary else 'not found (install checkra1n 0.12.4 or set CHECKRA1N)'}")
        print('\nManual DFU boot (never force recovery mode):')
        print('  1. Put the device in DFU mode manually.')
        print('  2. Boot checkra1n: checkra1n -c')
        print('  3. Connect root SSH over USB (e.g. iproxy 2222:22).')
        print('  4. Deploy and inspect:')
        print('       ./resize-apfs checkra1n deploy --host root@127.0.0.1 --port 2222')
        print('       ./resize-apfs checkra1n layout --host root@127.0.0.1 --port 2222')
        print('       ./resize-apfs checkra1n shrink --host root@127.0.0.1 --port 2222 --size 10')
        return 0

    require(bool(args.host), '--host is required (e.g. root@127.0.0.1).')
    if args.checkra1n_action == 'deploy':
        cmd = scp_command(helper['path'], args.host, remote_path=args.remote_path,
                          port=args.port, identity=args.identity)
        subprocess.run(cmd, check=True)
        chmod_cmd = ssh_base(args.host, port=args.port, identity=args.identity) + [
            f'chmod 755 {shlex.quote(args.remote_path)}'
        ]
        subprocess.run(chmod_cmd, check=True)
        print(f"Deployed {helper['path']} -> {args.host}:{args.remote_path} (sha256 {helper['sha256']})")
        return 0

    if args.checkra1n_action == 'layout':
        helper_args = ['--layout'] + (['--json'] if args.json else [])
        cmd = remote_helper_command(args.host, helper_args, remote_path=args.remote_path,
                                    port=args.port, identity=args.identity)
        return subprocess.run(cmd).returncode

    if args.checkra1n_action == 'shrink':
        require(bool(args.size), '--size is required (e.g. --size 10 for 10 GiB or --size 10GB).')
        helper_args = ['--shrink-to', args.size]
        if args.create_linux:
            helper_args.append('--create-linux')
        if args.yes:
            print('About to run an APFS + GPT shrink on the connected iOS device.')
            print(f'  Target : {args.size}')
            print(f'  Host   : {args.host} (port {args.port})')
            if input('Type yes to continue: ').strip() != 'yes':
                print('Shrink cancelled. Nothing was sent to the device.')
                return 0
            helper_args.append('--yes')
        cmd = remote_helper_command(args.host, helper_args, remote_path=args.remote_path,
                                    port=args.port, identity=args.identity)
        return subprocess.run(cmd).returncode

    raise ValueError('Unknown checkra1n action.')
