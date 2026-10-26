"""Discover the installed palera1n and its overlay capabilities."""
import hashlib
import os
import pathlib
import platform
import re
import shutil
import struct
import subprocess

from image_format import require

MINIMUM = (2, 4, 0)


def executable_slice(data):
    """Bound image discovery to one host slice, leaving non-fat inputs unchanged.

    Use the running process architecture (including under Rosetta). Do not guess
    between CPU subtypes or fall back to another architecture's boot payload.
    """
    formats = {b'\xca\xfe\xba\xbe': ('>', 'IIIII'),
               b'\xbe\xba\xfe\xca': ('<', 'IIIII'),
               b'\xca\xfe\xba\xbf': ('>', 'IIQQII'),
               b'\xbf\xba\xfe\xca': ('<', 'IIQQII')}
    if data[:4] not in formats:
        return data
    endian, fields = formats[data[:4]]
    require(len(data) >= 8, 'Malformed universal Mach-O: truncated header.')
    count = struct.unpack_from(endian + 'I', data, 4)[0]
    entry_size = struct.calcsize(endian + fields)
    table_end = 8 + count * entry_size
    require(count > 0 and table_end <= len(data), 'Malformed universal Mach-O: invalid architecture table.')
    slices = []
    for i in range(count):
        cpu, subtype, offset, size, align, *reserved = struct.unpack_from(endian + fields, data, 8 + i * entry_size)
        require(not reserved or reserved == [0], 'Malformed universal Mach-O: nonzero reserved field.')
        require(offset >= table_end and size >= 28 and offset + size <= len(data),
                'Malformed universal Mach-O: slice out of bounds.')
        require(align < (64 if reserved else 32) and offset % (1 << align) == 0,
                'Malformed universal Mach-O: invalid slice alignment.')
        magic = data[offset:offset + 4]
        thin = {b'\xce\xfa\xed\xfe': ('<', 28), b'\xcf\xfa\xed\xfe': ('<', 32),
                b'\xfe\xed\xfa\xce': ('>', 28), b'\xfe\xed\xfa\xcf': ('>', 32)}
        require(magic in thin, 'Malformed universal Mach-O: slice is not a thin Mach-O.')
        order, header_size = thin[magic]
        require(size >= header_size, 'Malformed universal Mach-O: truncated slice header.')
        actual_cpu, actual_subtype, filetype, commands, command_bytes = struct.unpack_from(order + 'IIIII', data, offset + 4)
        require((actual_cpu, actual_subtype) == (cpu, subtype),
                'Malformed universal Mach-O: slice architecture disagrees with table.')
        require(filetype == 2, 'Unsupported universal Mach-O: slice is not an executable.')
        require(commands * 8 <= command_bytes <= size - header_size,
                'Malformed universal Mach-O: load commands out of bounds.')
        slices.append((offset, offset + size, cpu, subtype))
    ordered = sorted(slices)
    require(all(a[1] <= b[0] for a, b in zip(ordered, ordered[1:])),
            'Malformed universal Mach-O: overlapping slices.')
    machine = platform.machine()
    host = {'arm64': (0x0100000c, 0), 'aarch64': (0x0100000c, 0),
            'x86_64': (0x01000007, 3)}.get(machine)
    require(host is not None, f'Unsupported universal Mach-O host architecture: {machine}.')
    matches = [s for s in slices if s[2] == host[0]]
    require(matches, f'Universal Mach-O has no slice for host architecture {machine}.')
    require(len(matches) == 1, f'Ambiguous universal Mach-O: multiple slices for {machine}.')
    start, end, _, subtype = matches[0]
    require(subtype & 0x00ffffff == host[1],
            f'Unsupported universal Mach-O CPU subtype 0x{subtype:x} for {machine}.')
    return data[start:end]


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
    data = binary.read_bytes()
    executable_slice(data)  # Diagnose malformed/unsupported fat metadata before executing it.
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
    return {'path': str(binary), 'version': '.'.join(map(str, version)),
            'installedBinarySHA256': hashlib.sha256(data).hexdigest(),
            'rootlessArguments': rootless}


def embedded_images(binary):
    data = executable_slice(pathlib.Path(binary).read_bytes())
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
