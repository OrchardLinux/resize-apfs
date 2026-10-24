"""Bounded readers for the partitionless UDIF/HFS images used by the overlay."""
import pathlib
import plistlib
import struct
import zlib

LIMIT = 512 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_udif(path):
    path = pathlib.Path(path)
    require(path.is_file() and path.stat().st_size <= LIMIT, 'Invalid or oversized disk image.')
    b = path.read_bytes()
    t = b[-512:]
    require(len(t) == 512 and t[:4] == b'koly', 'Missing UDIF footer.')
    require(struct.unpack_from('>II', t, 4) == (4, 512), 'Unsupported UDIF header.')
    sectors = struct.unpack_from('>Q', t, 492)[0]
    require(0 < sectors * 512 <= LIMIT, 'Invalid UDIF sector count.')
    offset, length = struct.unpack_from('>QQ', t, 24)
    xml, size = struct.unpack_from('>QQ', t, 216)
    require(offset + length <= xml and xml + size <= len(b) - 512, 'Invalid UDIF ranges.')
    require(struct.unpack_from('>II', t, 80) == (2, 32), 'Unsupported data checksum.')
    require(zlib.crc32(b[offset:offset + length]) == struct.unpack_from('>I', t, 88)[0], 'DMG data checksum mismatch.')
    entries = plistlib.loads(b[xml:xml + size])['resource-fork']['blkx']
    require(len(entries) == 1, 'Expected a partitionless overlay image.')
    table = entries[0]['Data']
    require(len(table) >= 204 and table[:4] == b'mish', 'Invalid DMG block map.')
    first, count, start_data = struct.unpack_from('>QQQ', table, 8)
    require(first == 0 and count == sectors, 'DMG footer and block map sizes disagree.')
    runs = struct.unpack_from('>I', table, 200)[0]
    require(len(table) == 204 + 40 * runs, 'Invalid block map length.')
    buffer = struct.unpack_from('>I', table, 32)[0] * 512
    raw = bytearray(count * 512)
    covered = crc = 0
    ended = False
    for i in range(runs):
        kind, _, start, num, pos, size = struct.unpack_from('>IIQQQQ', table, 204 + 40 * i)
        if kind == 0xffffffff:
            require(i == runs - 1, 'Misplaced block-map terminator.')
            ended = True
            continue
        if kind == 0x7ffffffe:
            continue
        require(start == covered and start + num <= count, 'Noncontiguous block map.')
        require(offset + start_data + pos + size <= xml, 'Compressed block exceeds the data fork.')
        data = b[offset + start_data + pos:offset + start_data + pos + size]
        if kind == 0x80000005:
            require(num * 512 <= buffer, 'Invalid decompression buffer size.')
            decoder = zlib.decompressobj()
            decoded = decoder.decompress(data, num * 512 + 1)
            require(decoder.eof and not decoder.unconsumed_tail, 'Invalid compressed block.')
        elif kind == 1:
            decoded = data
        elif kind in (0, 2):
            decoded = bytes(num * 512)
        else:
            raise ValueError(f'Unsupported DMG compression 0x{kind:x}; this overlay format needs a newer image backend.')
        require(len(decoded) == num * 512, 'Incorrect decompressed block size.')
        if kind not in (0, 2):
            crc = zlib.crc32(decoded, crc)
        raw[start * 512:(start + num) * 512] = decoded
        covered += num
    require(ended and covered == count, 'Incomplete block map.')
    require(struct.unpack_from('>II', table, 64) == (2, 32), 'Unsupported block checksum.')
    require(crc == struct.unpack_from('>I', table, 72)[0], 'Uncompressed block checksum mismatch.')
    require(struct.unpack_from('>II', t, 352) == (2, 32), 'Unsupported master checksum.')
    require(zlib.crc32(table[72:76]) == struct.unpack_from('>I', t, 360)[0], 'DMG master checksum mismatch.')
    return bytes(raw), t[64:80]


class HFSImage:
    def __init__(self, data):
        self.data = data
        require(1536 <= len(data) <= LIMIT, 'Invalid HFS image size.')
        self.header = data[1024:1536]
        require(self.header[:2] in (b'H+', b'HX'), 'Expected HFS+/HFSX.')
        require(not struct.unpack_from('>I', self.header, 4)[0] & (1 << 13), 'Journaled build images are unsupported.')
        self.block, total = struct.unpack_from('>II', self.header, 40)
        require(512 <= self.block <= 1048576 and self.block & (self.block - 1) == 0, 'Invalid HFS block size.')
        require(0 <= len(data) - total * self.block < self.block, 'HFS volume size mismatch.')
        self.volume_id = self.header[104:112]
        catalog = self.fork(self.header[272:352])
        require(len(catalog) >= 40, 'Missing HFS catalog.')
        node_size = struct.unpack_from('>H', catalog, 32)[0]
        nodes = struct.unpack_from('>I', catalog, 36)[0]
        require(512 <= node_size <= 32768 and node_size & (node_size - 1) == 0 and nodes * node_size <= len(catalog), 'Invalid catalog geometry.')
        records = {}
        for node in range(nodes):
            base = node * node_size
            if catalog[base + 8] != 0xff:
                continue
            n = struct.unpack_from('>H', catalog, base + 10)[0]
            require(n < node_size // 4, 'Invalid catalog record count.')
            for i in range(n):
                a = struct.unpack_from('>H', catalog, base + node_size - 2 * (i + 1))[0]
                end = struct.unpack_from('>H', catalog, base + node_size - 2 * (i + 2))[0]
                require(14 <= a < end <= node_size - 2 * (n + 1), 'Invalid catalog offsets.')
                key = base + a
                length, parent, chars = struct.unpack_from('>HIH', catalog, key)
                start = key + 2 + length
                require(length >= 6 + chars * 2 and start + 2 <= base + end, 'Invalid catalog key.')
                kind = struct.unpack_from('>H', catalog, start)[0]
                if kind not in (1, 2):
                    continue
                require(start + (248 if kind == 2 else 88) <= base + end, 'Truncated catalog record.')
                name = catalog[key + 8:key + 8 + 2 * chars].decode('utf-16-be')
                reserved = name in ('\0' * 4 + 'HFS+PrivateDirectoryData', '\0' * 4 + 'HFS+ Private Data')
                require('/' not in name and ('\0' not in name or reserved) and name not in ('.', '..'), 'Unsafe HFS filename.')
                cnid = struct.unpack_from('>I', catalog, start + 8)[0]
                uid, gid = struct.unpack_from('>II', catalog, start + 32)
                mode = struct.unpack_from('>H', catalog, start + 42)[0]
                records[cnid] = {'parent': parent, 'name': name, 'kind': kind, 'uid': uid, 'gid': gid,
                                 'mode': mode, 'fork': catalog[start + 88:start + 168] if kind == 2 else None}
        self.entries = {}
        for cnid, record in records.items():
            pieces = []
            cursor = cnid
            seen = set()
            while cursor != 2:
                require(cursor in records and cursor not in seen and len(seen) < 128, 'Invalid catalog hierarchy.')
                seen.add(cursor)
                pieces.append(records[cursor]['name'])
                cursor = records[cursor]['parent']
            path = '/' + '/'.join(reversed(pieces))
            require(path not in self.entries, 'Duplicate catalog path.')
            self.entries[path] = record

    def fork(self, fork):
        require(len(fork) == 80, 'Invalid HFS fork.')
        length = struct.unpack_from('>Q', fork)[0]
        require(length <= LIMIT, 'Oversized HFS fork.')
        data = bytearray()
        for i in range(8):
            start, count = struct.unpack_from('>II', fork, 16 + i * 8)
            require((start + count) * self.block <= len(self.data), 'HFS extent out of bounds.')
            data.extend(self.data[start * self.block:(start + count) * self.block][:max(0, length - len(data))])
        require(len(data) == length, 'HFS overflow extents are unsupported.')
        return bytes(data)

    def read(self, path):
        require(path in self.entries and self.entries[path]['kind'] == 2, f'Missing file: {path}')
        return self.fork(self.entries[path]['fork'])
