#!/usr/bin/env python3
"""Build a Resize APFS overlay from the installed palera1n binpack.

Only generated disk-image files are mounted/modified. Never contacts a device.
"""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]

def run(*args):
    subprocess.run([str(a) for a in args], check=True)

def image(folder, destination, name, scratch):
    raw = scratch / (name + '-raw.dmg')
    run('hdiutil', 'create', '-format', 'UDRW', '-fs', 'HFSX', '-layout', 'NONE',
        '-srcfolder', folder, '-volname', name, '-nospotlight', raw)
    run('python3', ROOT/'scripts/hfs-root-ownership.py', raw)
    run('hdiutil', 'convert', raw, '-format', 'UDZO', '-imagekey', 'zlib-level=9', '-o', destination)
    run('hdiutil', 'verify', destination)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--enable-writes', action='store_true', help='Enable storage changes reviewed and confirmed in the app')
parser.add_argument('--output', type=pathlib.Path)
args = parser.parse_args()
mode = 'write' if args.enable_writes else 'inspect'
destination = (args.output or ROOT/f'out/resize-apfs-{mode}.dmg').resolve()
if destination.exists(): parser.error('Output already exists; choose a different --output path.')
device = ROOT/'out/device'
for required in ['ResizeAPFS.app/ResizeAPFS', 'resize-helper', 'resize-overlay-entry', 'manifest.json']:
    if not (device/required).is_file(): parser.error('run scripts/build-device.sh first')
work = ROOT/'.work'
work.mkdir(exist_ok=True)
base = work/'base-binpack.dmg'
run('python3', ROOT/'scripts/extract-binpack.py', '--output', base)
destination.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='overlay-', dir=work) as temp:
    scratch = pathlib.Path(temp)
    mounted = scratch/'base'
    mounted.mkdir()
    attached = False
    try:
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mounted, base)
        attached = True
        stage = scratch/'binpack'
        run('ditto', mounted, stage)
    finally:
        if attached: run('hdiutil', 'detach', mounted)
    for required in ['bin/launchctl', 'usr/bin/uicache', 'usr/sbin/palera1nd',
                     'Library/LaunchDaemons/palera1nd.plist', 'loader.dmg']:
        if not ((stage/required).exists() or (stage/required).is_symlink()):
            parser.error('base overlay is missing a required boot component: '+required)

    apps = scratch/'apps'
    apps.mkdir()
    # Stock jbinit mounts loader.dmg onto /cores/binpack/Applications and registers
    # this exact path. Reuse it; replace the entire bundle, not just its binary.
    run('ditto', device/'ResizeAPFS.app', apps/'palera1nLoader.app')
    (stage/'loader.dmg').unlink()
    image(apps, stage/'loader.dmg', 'ResizeAPFSApps', scratch)
    # The app targets iPhone/iPad; omit the stock tvOS loader.
    if (stage/'tvloader.dmg').exists(): (stage/'tvloader.dmg').unlink()

    libexec = stage/'usr/libexec'
    libexec.mkdir(parents=True, exist_ok=True)
    for executable in ['resize-helper', 'resize-overlay-entry']:
        shutil.copy2(device/executable, libexec/executable)
        (libexec/executable).chmod(0o755)
    daemons = stage/'Library/LaunchDaemons'
    config = plistlib.loads((ROOT/'Device/dev.omarchy.resize-apfs.plist').read_bytes())
    if args.enable_writes: config['ProgramArguments'].append('--allow-writes')
    (daemons/'dev.omarchy.resize-apfs.plist').write_bytes(plistlib.dumps(config))

    original = plistlib.loads((daemons/'palera1nd.plist').read_bytes())
    original['Program'] = '/cores/binpack/usr/libexec/resize-overlay-entry'
    original['ProgramArguments'] = [original['Program']]
    original['RunAtLoad'] = True
    (daemons/'palera1nd.plist').write_bytes(plistlib.dumps(original))

    # No stock overlay SSH, telnet or debug-shell listeners. Existing jailbreak
    # services outside this image are the user's state and are not altered.
    for path in daemons.glob('*.plist'):
        if path.name.startswith(('dropbear-', 'telnetd', 'debug-shell')):
            value = plistlib.loads(path.read_bytes())
            value['Disabled'] = True
            value.pop('Sockets', None)
            path.write_bytes(plistlib.dumps(value))
        path.chmod(0o644)
    image(stage, destination, 'ResizeAPFSOverlay', scratch)

lock = json.loads((ROOT/'Device/upstream.lock.json').read_text())
manifest = {
    'mode': mode,
    'overlay': destination.name,
    'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
    'bytes': destination.stat().st_size,
    'palera1n': lock['palera1n'],
    'deviceBuild': json.loads((device/'manifest.json').read_text()),
    'stockPalera1nAppIncluded': False,
    'networkListenersEnabled': False,
    'hardwareTested': False
}
destination.with_suffix('.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(f'Built {mode} overlay: {destination}')
