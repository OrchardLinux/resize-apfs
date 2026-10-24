#!/usr/bin/env python3
"""Read-only audit of a generated overlay and its nested app image."""
import argparse, hashlib, json, pathlib, plistlib, subprocess, tempfile, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('image', type=pathlib.Path)
args = parser.parse_args()
image = args.image.resolve()
manifest = json.loads(image.with_suffix('.json').read_text())
assert hashlib.sha256(image.read_bytes()).hexdigest() == manifest['sha256'], 'Overlay hash mismatch'
(ROOT/'.work').mkdir(exist_ok=True)
if sys.platform.startswith('linux'):
    from overlay_linux import audit
    audit(image, manifest)
    raise SystemExit(0)

def attach(image, mount):
    subprocess.run(['hdiutil','attach','-readonly','-owners','on','-nobrowse','-mountpoint',str(mount),str(image)],check=True)
def detach(mount):
    subprocess.run(['hdiutil','detach',str(mount)],check=True)
def load(path): return plistlib.loads(path.read_bytes())
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

with tempfile.TemporaryDirectory(prefix='audit-overlay-',dir=ROOT/'.work') as temp:
    root = pathlib.Path(temp)
    outer, apps = root/'outer', root/'apps'
    outer.mkdir(); apps.mkdir()
    outer_attached = apps_attached = False
    try:
        attach(image,outer); outer_attached=True
        daemon = outer/'Library/LaunchDaemons/dev.omarchy.resize-apfs.plist'
        config = load(daemon)
        assert config['ProgramArguments'][0] == '/cores/binpack/usr/libexec/resize-helper'
        assert ('--allow-writes' in config['ProgramArguments']) == (manifest['mode']=='write')
        assert config['KeepAlive'] and config['RunAtLoad'] and config['AbandonProcessGroup']
        for path in [outer,daemon,outer/'usr/libexec/resize-helper',outer/'usr/libexec/resize-overlay-entry']:
            assert path.stat().st_uid == 0, f'Not root-owned on disk: {path}'
        for name in ['resize-helper','resize-overlay-entry']:
            assert sha(outer/f'usr/libexec/{name}') == manifest['deviceBuild']['files'][name]['sha256']
            assert (outer/f'usr/libexec/{name}').stat().st_mode & 0o111
        original=load(outer/'Library/LaunchDaemons/palera1nd.plist')
        assert original['Program']=='/cores/binpack/usr/libexec/resize-overlay-entry'
        assert original['RunAtLoad'] and original['Label']=='in.palera.palera1nd'
        assert (outer/'usr/sbin/palera1nd').is_symlink()
        assert (outer/'usr/sbin/palera1nd').readlink() == pathlib.Path('../../../payload')
        for path in (outer/'Library/LaunchDaemons').glob('*.plist'):
            if path.name.startswith(('dropbear-','telnetd','debug-shell')):
                value=load(path)
                assert value.get('Disabled') is True and 'Sockets' not in value
        assert not (outer/'tvloader.dmg').exists()
        attach(outer/'loader.dmg',apps); apps_attached=True
        bundles=list(apps.glob('*.app'))
        assert len(bundles)==1 and bundles[0].name=='palera1nLoader.app'
        app=bundles[0]; info=load(app/'Info.plist')
        assert info['CFBundleIdentifier']=='dev.omarchy.resize-apfs'
        assert info['CFBundleDisplayName']=='Resize APFS'
        assert sha(app/info['CFBundleExecutable'])==manifest['deviceBuild']['files']['ResizeAPFS.app/ResizeAPFS']['sha256']
        assert app.stat().st_uid==0
        assert not list(app.rglob('*.mobileprovision'))
        subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
        signature=subprocess.run(['codesign','-dvv',str(app)],capture_output=True,text=True,check=True).stderr
        assert 'TeamIdentifier=not set' in signature and 'Authority=' not in signature
    finally:
        if apps_attached: detach(apps)
        if outer_attached: detach(outer)
print('PASS: overlay contents, ownership, configuration and signatures verified.')
