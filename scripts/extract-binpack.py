#!/usr/bin/env python3
"""Extract the checksum-pinned UDIF overlay embedded in the installed palera1n."""
import argparse, hashlib, json, pathlib, shutil, struct, subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--palera1n', default=shutil.which('palera1n'))
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
lock = json.loads((ROOT/'Device/upstream.lock.json').read_text())['palera1n']
if not args.palera1n:
    parser.error('palera1n is not in PATH')
binary = pathlib.Path(args.palera1n).read_bytes()
if hashlib.sha256(binary).hexdigest() != lock['installedBinarySHA256']:
    parser.error('Unsupported palera1n binary. See Device/upstream.lock.json for the supported artifact.')
found = []
position = 0
while True:
    at = binary.find(b'koly', position)
    if at < 0: break
    position = at + 4
    if at + 512 > len(binary) or struct.unpack_from('>I', binary, at+8)[0] != 512: continue
    xml_offset, xml_length = struct.unpack_from('>QQ', binary, at+216)
    start = at - xml_offset - xml_length
    if start < 0 or start > at: continue
    candidate = binary[start:at+512]
    if hashlib.sha256(candidate).hexdigest() == lock['embeddedBinpackSHA256']: found.append(candidate)
if len(found) != 1:
    parser.error('could not identify exactly one matching embedded overlay')
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_bytes(found[0])
subprocess.run(['hdiutil','verify',str(args.output)],check=True)
print(f'Extracted verified original binpack: {args.output}')
