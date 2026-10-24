#!/usr/bin/env python3
"""Build a Resize APFS overlay using the installed palera1n."""
import argparse
import hashlib
import json
import pathlib
import platform
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--enable-writes', action='store_true', help='Enable changes reviewed and confirmed in the app')
parser.add_argument('--output', type=pathlib.Path)
args = parser.parse_args()
mode = 'write' if args.enable_writes else 'inspect'
destination = (args.output or ROOT / f'out/resize-apfs-{mode}.dmg').resolve()
if destination.exists():
    parser.error('Output already exists; choose a different --output path.')
device = ROOT / 'out/device'
for required in ['ResizeAPFS.app/ResizeAPFS', 'resize-helper', 'resize-overlay-entry', 'manifest.json']:
    if not (device / required).is_file():
        parser.error('Missing device payload. Use the release ZIP or run scripts/build-device.sh.')
(ROOT / '.work').mkdir(exist_ok=True)
destination.parent.mkdir(parents=True, exist_ok=True)
base = destination.with_name(destination.stem + '-base.dmg')
try:
    subprocess.run([sys.executable, str(ROOT / 'scripts/extract-binpack.py'), '--output', str(base)], check=True)
    producer = json.loads(base.with_suffix('.json').read_text())
    if sys.platform == 'darwin':
        from overlay_macos import build
    elif sys.platform.startswith('linux'):
        from overlay_linux import build
    else:
        raise ValueError('Overlay preparation supports Linux and macOS.')
    build(base, destination, args.enable_writes)
    manifest = {'mode': mode, 'overlay': destination.name,
                'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
                'bytes': destination.stat().st_size, 'palera1n': producer,
                'deviceBuild': json.loads((device / 'manifest.json').read_text()),
                'preparation': {'os': platform.system(), 'architecture': platform.machine()},
                'stockPalera1nAppIncluded': False, 'networkListenersEnabled': False}
    destination.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    subprocess.run([sys.executable, str(ROOT / 'scripts/audit-overlay.py'), str(destination)], check=True)
    print(f'Built {mode} overlay: {destination}')
except (ValueError, OSError, subprocess.CalledProcessError) as error:
    destination.unlink(missing_ok=True)
    destination.with_suffix('.json').unlink(missing_ok=True)
    parser.exit(1, str(error) + '\n')
finally:
    base.unlink(missing_ok=True)
    base.with_suffix('.json').unlink(missing_ok=True)
