#!/usr/bin/env python3
"""Set catalog UID/GID to 0 in our unmounted, nonjournaled raw HFS+ build image.

No sudo or host chown required. Refuses unsupported signatures, journaled volumes,
catalog overflow extents and malformed B-tree nodes. Never opens a device node.
"""
import argparse, os, pathlib, stat, struct

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('image', type=pathlib.Path)
args = parser.parse_args()
if not stat.S_ISREG(args.image.lstat().st_mode): parser.error('expected a regular image file, not a device/symlink')
with args.image.open('r+b') as f:
    f.seek(1024); header = f.read(512)
    if header[:2] not in (b'H+', b'HX'): parser.error('raw HFS+/HFSX volume expected at offset zero')
    attributes = struct.unpack_from('>I', header, 4)[0]
    if attributes & (1 << 13): parser.error('journaled volume is not supported')
    block_size = struct.unpack_from('>I', header, 40)[0]
    if block_size < 512 or block_size > 1048576 or block_size & (block_size - 1): parser.error('invalid HFS block size')
    catalog_size = struct.unpack_from('>Q', header, 272)[0]
    extents = [struct.unpack_from('>II', header, 288+i*8) for i in range(8)]
    if catalog_size <= 0 or catalog_size > 128*1024*1024: parser.error('unbounded catalog size')
    if sum(count for _,count in extents)*block_size < catalog_size: parser.error('catalog overflow extents unsupported')
    catalog = bytearray()
    for start,count in extents:
        if count:
            f.seek(start*block_size); catalog += f.read(count*block_size)
    node_size = struct.unpack_from('>H',catalog,32)[0]
    total_nodes = struct.unpack_from('>I',catalog,36)[0]
    if node_size < 512 or node_size > 32768 or node_size & (node_size-1) or total_nodes*node_size > len(catalog): parser.error('invalid B-tree geometry')
    changed = 0
    for node in range(total_nodes):
        base = node*node_size
        if catalog[base+8] != 0xff: continue
        records = struct.unpack_from('>H',catalog,base+10)[0]
        if records > node_size//4: parser.error('invalid leaf record count')
        for index in range(records):
            offset = struct.unpack_from('>H',catalog,base+node_size-2*(index+1))[0]
            if offset < 14 or offset+2 > node_size-2*(records+1): parser.error('invalid record offset')
            key_length = struct.unpack_from('>H',catalog,base+offset)[0]
            data = base+offset+2+key_length
            end_offset = struct.unpack_from('>H',catalog,base+node_size-2*(index+2))[0]
            record_end = base+end_offset
            if data+2 > record_end or record_end > base+node_size-2*(records+1): parser.error('invalid catalog key/record')
            kind = struct.unpack_from('>H',catalog,data)[0]
            if kind in (1,2):
                if data+48 > record_end: parser.error('truncated catalog permissions')
                struct.pack_into('>II',catalog,data+32,0,0)
                changed += 1
    cursor = 0
    for start,count in extents:
        if count:
            length = count*block_size
            f.seek(start*block_size); f.write(catalog[cursor:cursor+length]); cursor += length
    f.flush(); os.fsync(f.fileno())
print(f'Root ownership recorded for {changed} catalog files/folders in {args.image}')
