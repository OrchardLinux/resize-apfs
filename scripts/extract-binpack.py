#!/usr/bin/env python3
"""Extract a structurally compatible overlay from the installed palera1n."""
import argparse
import hashlib
import json
import pathlib
import stat

from image_format import HFSImage, read_udif, require
from palera import discover, embedded_images

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--palera1n')
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
try:
    info = discover(args.palera1n)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists() or args.output.is_symlink():
        require(stat.S_ISREG(args.output.lstat().st_mode), 'Output must be a regular image file.')
    candidates = []
    errors = []
    scratch = args.output.with_name(args.output.name + '.candidate')
    require(not scratch.exists() and not scratch.is_symlink(), 'Extraction scratch file already exists.')
    try:
        for image in embedded_images(info['path']):
            scratch.write_bytes(image)
            try:
                raw, _ = read_udif(scratch)
                fs = HFSImage(raw)
                required = ['/loader.dmg', '/Library/LaunchDaemons/palera1nd.plist', '/usr/libexec/try_uicache.sh', '/bin/launchctl', '/usr/bin/uicache', '/usr/sbin/palera1nd']
                require(all(p in fs.entries for p in required), 'Missing required boot components.')
                require(fs.read('/usr/sbin/palera1nd') == b'../../../payload', 'Unsupported daemon layout.')
                candidates.append(image)
            except (ValueError, KeyError) as error:
                errors.append(str(error))
        require(len(candidates) == 1, 'No unique compatible palera1n overlay found. ' + '; '.join(errors[:2]))
        args.output.write_bytes(candidates[0])
        producer = {k: v for k, v in info.items() if k != 'path'}
        producer['embeddedBinpackSHA256'] = hashlib.sha256(candidates[0]).hexdigest()
        args.output.with_suffix('.json').write_text(json.dumps(producer, indent=2) + '\n')
    finally:
        scratch.unlink(missing_ok=True)
    print('Extracted compatible palera1n overlay.')
except (ValueError, OSError) as error:
    parser.exit(1, str(error) + '\n')
