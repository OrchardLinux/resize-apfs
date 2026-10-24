"""Discover the installed palera1n and its overlay capabilities."""
import hashlib
import os
import pathlib
import re
import shutil
import struct
import subprocess

MINIMUM = (2, 4, 0)


def version_from(text):
    patterns = [r'Build tag:\s*v?(\d+)\.(\d+)(?:\.(\d+))?',
                r'palera1n:\s*v?(\d+)\.(\d+)(?:\.(\d+))?',
                r'palera1n\s+v?(\d+)\.(\d+)(?:\.(\d+))?']
    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            return tuple(int(x or 0) for x in match.groups())
    raise ValueError('Cannot determine the palera1n version. Install the official CLI release.')


def discover(selected=None):
    selected = selected or os.environ.get('PALERA1N') or shutil.which('palera1n')
    if not selected:
        raise ValueError('Install palera1n separately and put it in PATH (or set PALERA1N).')
    binary = pathlib.Path(shutil.which(selected) or selected).resolve()
    result = subprocess.run([str(binary), '--version'], capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise ValueError('palera1n --version failed. Check that this executable runs on your host.')
    version = version_from(result.stdout + result.stderr)
    if version < MINIMUM:
        raise ValueError('palera1n 2.4 or later is required.')
    result = subprocess.run([str(binary), '--help'], capture_output=True, text=True, timeout=15)
    help_text = result.stdout + result.stderr
    if '--override-overlay' not in help_text:
        raise ValueError('This palera1n build does not support custom overlays.')
    # Rootless-only builds need no mode switch. Rootful-capable builds expose one.
    rootless = ['--rootless'] if '--rootless' in help_text else []
    if not rootless and '--fakefs' in help_text:
        raise ValueError('Cannot select rootless mode with this palera1n build.')
    data = binary.read_bytes()
    return {'path': str(binary), 'version': '.'.join(map(str, version)),
            'installedBinarySHA256': hashlib.sha256(data).hexdigest(),
            'rootlessArguments': rootless}


def embedded_images(binary):
    data = pathlib.Path(binary).read_bytes()
    position = 0
    while True:
        at = data.find(b'koly', position)
        if at < 0:
            break
        position = at + 4
        if at + 512 > len(data) or struct.unpack_from('>II', data, at + 4) != (4, 512):
            continue
        offset, length = struct.unpack_from('>QQ', data, at + 216)
        start = at - offset - length
        if start < 0 or start > at or length == 0:
            continue
        yield data[start:at + 512]
