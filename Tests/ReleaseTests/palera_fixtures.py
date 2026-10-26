"""Synthetic, non-runnable executables and tiny structurally valid overlay images."""
import pathlib
import stat
import struct

from test_portable_images import image

ARM64 = 0x0100000c
X86_64 = 0x01000007


def thin(payload, cpu=ARM64, subtype=None):
    if subtype is None:
        subtype = 3 if cpu == X86_64 else 0
    return struct.pack('<IIIIIIII', 0xfeedfacf, cpu, subtype, 2, 0, 0, 0, 0) + payload


def universal(slices, endian='>', wide=False):
    fields = 'IIQQII' if wide else 'IIIII'
    data = bytearray(struct.pack(endian + 'II', 0xcafebabf if wide else 0xcafebabe, len(slices)))
    data.extend(bytes(struct.calcsize(fields) * len(slices)))
    for i, part in enumerate(slices):
        data.extend(bytes(-len(data) % 8))
        cpu, subtype = struct.unpack_from('<II', part, 4)
        entry = [cpu, subtype, len(data), len(part), 3] + ([0] if wide else [])
        struct.pack_into(endian + fields, data, 8 + i * struct.calcsize(fields), *entry)
        data.extend(part)
    return bytes(data)


def elf(payload):
    return struct.pack('<16sHHIQQQIHHHHHH', b'\x7fELF\x02\x01\x01' + bytes(9),
                       2, 62, 1, 0, 0, 0, 0, 64, 56, 0, 64, 0, 0) + payload


def overlay(marker=b'loader', daemon=b'../../../payload', omit=None):
    files = {'/loader.dmg': marker, '/Library/LaunchDaemons/palera1nd.plist': b'plist',
             '/usr/libexec/try_uicache.sh': b'script', '/bin/launchctl': b'launchctl',
             '/usr/bin/uicache': b'uicache', '/usr/sbin/palera1nd': daemon}
    files.pop(omit, None)
    paths = {'/'}
    for path in files:
        paths.add(path)
        paths.update(str(p) for p in pathlib.PurePosixPath(path).parents)
    paths = sorted(paths)
    ids = {path: i + 2 for i, path in enumerate(paths)}
    # Volume header, two catalog nodes, then one block per small file.
    raw = bytearray((19 + len(files)) * 512)
    raw[1024:1026] = b'HX'
    struct.pack_into('>II', raw, 1064, 512, len(raw) // 512)

    def fork(target, offset, length, block, count):
        struct.pack_into('>Q', target, offset, length)
        struct.pack_into('>I', target, offset + 12, count)
        struct.pack_into('>II', target, offset + 16, block, count)

    fork(raw, 1024 + 272, 8192, 3, 16)
    catalog = bytearray(8192)
    struct.pack_into('>H', catalog, 32, 4096)  # node size
    struct.pack_into('>I', catalog, 36, 2)  # total nodes
    catalog[4096 + 8] = 0xff
    struct.pack_into('>H', catalog, 4096 + 10, len(paths))
    offset, block = 14, 19
    for i, path in enumerate(paths):
        name = pathlib.PurePosixPath(path)
        encoded = name.name.encode('utf-16-be')
        key = struct.pack('>HIH', 6 + len(encoded), ids.get(str(name.parent), 1), len(encoded) // 2) + encoded
        is_file = path in files
        record = bytearray(248 if is_file else 88)
        struct.pack_into('>H', record, 0, 2 if is_file else 1)
        struct.pack_into('>I', record, 8, ids[path])
        mode = stat.S_IFLNK if path == '/usr/sbin/palera1nd' else stat.S_IFREG if is_file else stat.S_IFDIR
        struct.pack_into('>H', record, 42, mode | 0o755)
        if is_file:
            contents = files[path]
            assert len(contents) <= 512
            raw[block * 512:block * 512 + len(contents)] = contents
            fork(record, 88, len(contents), block, 1)
            block += 1
        struct.pack_into('>H', catalog, 8192 - 2 * (i + 1), offset)
        catalog[4096 + offset:4096 + offset + len(key) + len(record)] = key + record
        offset += len(key) + len(record)
    assert offset < 4096 - 2 * (len(paths) + 1)
    struct.pack_into('>H', catalog, 8192 - 2 * (len(paths) + 1), offset)
    raw[1536:1536 + len(catalog)] = catalog
    return image(sectors=len(raw) // 512, raw=bytes(raw))
