"""macOS image preparation using the system disk-image tools."""
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
    run('python3', ROOT / 'scripts/hfs-root-ownership.py', raw)
    run('hdiutil', 'convert', raw, '-format', 'UDZO', '-imagekey', 'zlib-level=9', '-o', destination)
    run('hdiutil', 'verify', destination)


def build(base, destination, writes):
    device = ROOT / 'out/device'
    with tempfile.TemporaryDirectory(prefix='overlay-', dir=ROOT / '.work') as temporary:
        scratch = pathlib.Path(temporary)
        mount = scratch / 'base'
        mount.mkdir()
        attached = False
        try:
            run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, base)
            attached = True
            stage = scratch / 'binpack'
            run('ditto', mount, stage)
        finally:
            if attached:
                run('hdiutil', 'detach', mount)
        apps = scratch / 'apps'
        apps.mkdir()
        run('ditto', device / 'ResizeAPFS.app', apps / 'palera1nLoader.app')
        (stage / 'loader.dmg').unlink()
        image(apps, stage / 'loader.dmg', 'ResizeAPFSApps', scratch)
        (stage / 'tvloader.dmg').unlink(missing_ok=True)
        libexec = stage / 'usr/libexec'
        libexec.mkdir(parents=True, exist_ok=True)
        for executable in ['resize-helper', 'resize-overlay-entry']:
            shutil.copy2(device / executable, libexec / executable)
            (libexec / executable).chmod(0o755)
        daemons = stage / 'Library/LaunchDaemons'
        config = plistlib.loads((ROOT / 'Device/dev.omarchy.resize-apfs.plist').read_bytes())
        if writes:
            config['ProgramArguments'].append('--allow-writes')
        (daemons / 'dev.omarchy.resize-apfs.plist').write_bytes(plistlib.dumps(config))
        original = plistlib.loads((daemons / 'palera1nd.plist').read_bytes())
        original['Program'] = '/cores/binpack/usr/libexec/resize-overlay-entry'
        original['ProgramArguments'] = [original['Program']]
        original['RunAtLoad'] = True
        (daemons / 'palera1nd.plist').write_bytes(plistlib.dumps(original))
        for path in daemons.glob('*.plist'):
            if path.name.startswith(('dropbear-', 'telnetd', 'debug-shell')):
                value = plistlib.loads(path.read_bytes())
                value['Disabled'] = True
                value.pop('Sockets', None)
                path.write_bytes(plistlib.dumps(value))
            path.chmod(0o644)
        image(stage, destination, 'ResizeAPFSOverlay', scratch)
