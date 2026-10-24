"""Package the prebuilt app and portable launch tools; never include palera1n."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('version', nargs='?', default='preview')
parser.add_argument('--require-linux-tools', action='store_true')
parser.add_argument('--replace', action='store_true', help='Atomically replace an existing local ZIP')
args = parser.parse_args()
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', args.version):
    parser.error('Invalid version.')
name = 'ResizeAPFS-' + args.version
output = ROOT / 'out/releases'
output.mkdir(parents=True, exist_ok=True)
(ROOT / '.work').mkdir(exist_ok=True)
archive = output / (name + '.zip')
if archive.exists() and not args.replace:
    parser.error('Output already exists: ' + str(archive))
subprocess.run([sys.executable, str(ROOT / 'scripts/check-release.py')], check=True)
device = ROOT / 'out/device'
manifest = json.loads((device / 'manifest.json').read_text())
for relative, expected in manifest['files'].items():
    path = device / relative
    if not path.resolve().is_relative_to(device.resolve()) or path.is_symlink():
        parser.error('Unsafe payload path.')
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected['sha256']:
        parser.error('Payload checksum mismatch: ' + relative)
if sys.platform == 'darwin':
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(device / 'ResizeAPFS.app')], check=True)
    signature = subprocess.run(['codesign', '-dvv', str(device / 'ResizeAPFS.app')], capture_output=True, text=True, check=True).stderr
    if 'TeamIdentifier=not set' not in signature or 'Authority=' in signature:
        parser.error('Unexpected developer identity.')
with tempfile.TemporaryDirectory(prefix='release-', dir=ROOT / '.work') as temporary:
    package = pathlib.Path(temporary) / name
    (package / 'scripts').mkdir(parents=True)
    (package / 'Device').mkdir()
    for file in ['README.md', 'THIRD_PARTY_NOTICES.md', 'LICENSE', 'resize-apfs']:
        shutil.copy2(ROOT / file, package / file)
    scripts = ['launcher.py', 'palera.py', 'boot_device.py', 'boot-device.sh', 'build-overlay.py',
               'extract-binpack.py', 'overlay_linux.py', 'overlay_macos.py', 'image_format.py',
               'hfs-root-ownership.py', 'audit-overlay.py', 'build-linux-tools.sh']
    for script in scripts:
        shutil.copy2(ROOT / 'scripts' / script, package / 'scripts' / script)
    for file in ['upstream.lock.json', 'dev.omarchy.resize-apfs.plist', 'README.md']:
        shutil.copy2(ROOT / 'Device' / file, package / 'Device' / file)
    shutil.copytree(device, package / 'out/device')
    for relative, expected in manifest['files'].items():
        mode = expected.get('mode', 0o755 if relative in ['ResizeAPFS.app/ResizeAPFS', 'resize-helper', 'resize-overlay-entry'] else 0o644)
        (package / 'out/device' / relative).chmod(mode)
    shutil.copytree(ROOT / 'docs/screenshots', package / 'docs/screenshots')
    shutil.copytree(ROOT / 'third_party/libdmg-hfsplus', package / 'third_party/libdmg-hfsplus')
    for arch in ['x86_64', 'arm64']:
        source = ROOT / 'out/host-tools' / ('linux-' + arch)
        if not all((source / tool).is_file() for tool in ['dmg', 'hfsplus']):
            if args.require_linux_tools:
                parser.error('Missing Linux tools: ' + arch)
            continue
        target = package / 'tools' / ('linux-' + arch)
        target.mkdir(parents=True)
        for tool in ['dmg', 'hfsplus']:
            shutil.copy2(source / tool, target / tool)
            (target / tool).chmod(0o755)
    (package / 'resize-apfs').chmod(0o755)
    (package / 'scripts/boot-device.sh').chmod(0o755)
    (package / 'scripts/build-linux-tools.sh').chmod(0o755)
    files = sorted(p for p in package.rglob('*') if p.is_file())
    if any(p.is_symlink() or p.suffix == '.mobileprovision' for p in package.rglob('*')):
        parser.error('Unexpected symlink or provisioning profile.')
    (package / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(package)}\n' for p in files))
    subprocess.run([sys.executable, str(ROOT / 'scripts/check-release.py'), '--release-dir', str(package)], check=True)
    pending = archive.with_suffix('.zip.pending')
    try:
        with zipfile.ZipFile(pending, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            for path in sorted(p for p in package.rglob('*') if p.is_file()):
                z.write(path, str(path.relative_to(package.parent)))
        os.replace(pending, archive)
    finally:
        pending.unlink(missing_ok=True)
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_name(archive.name + '.sha256').write_text(f'{checksum}  {archive.name}\n')
print('Created', archive)
