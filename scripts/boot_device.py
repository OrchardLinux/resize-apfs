"""Validate a prepared overlay and invoke the external palera1n."""
import argparse
import hashlib
import json
import os
import pathlib
import shlex
import shutil
import sys

from image_format import require
from palera import discover, embedded_images


def command(image, info):
    image = pathlib.Path(image).resolve()
    require(image.is_file() and image.stat().st_size <= 512 * 1024 * 1024, 'Expected a regular overlay image.')
    manifest = json.loads(image.with_suffix('.json').read_text())
    require(hashlib.sha256(image.read_bytes()).hexdigest() == manifest['sha256'], 'Overlay checksum mismatch.')
    producer = manifest['palera1n']
    if info['installedBinarySHA256'] != producer['installedBinarySHA256']:
        expected = producer['embeddedBinpackSHA256']
        require(sum(hashlib.sha256(data).hexdigest() == expected for data in embedded_images(info['path'])) == 1,
                'palera1n changed its boot payload. Prepare a new overlay for the installed version.')
    result = [info['path'], *info['rootlessArguments'], '--override-overlay', str(image)]
    if sys.platform.startswith('linux') and os.geteuid() != 0:
        require(shutil.which('sudo') is not None, 'sudo is required to give palera1n USB access.')
        result.insert(0, shutil.which('sudo'))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--overlay', type=pathlib.Path, required=True)
    parser.add_argument('--boot', action='store_true')
    args = parser.parse_args()
    try:
        argv = command(args.overlay, discover())
        if not args.boot:
            print('Boot command:', shlex.join(argv))
            print('Rerun with --boot to start palera1n.')
        else:
            print('Starting palera1n...', flush=True)
            os.execv(argv[0], argv)
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, str(error) + '\n')
