#!/bin/bash
# Package our prebuilt payload only. Never include palera1n or assembled images.
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:-preview}
[[ $version =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo 'Invalid version' >&2; exit 2; }
[[ -f out/device/manifest.json ]] || { echo 'Run scripts/build-device.sh first.' >&2; exit 1; }
python3 scripts/check-release.py
mkdir -p out/releases .work
stage=$(mktemp -d "$PWD/.work/release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
name="ResizeAPFS-$version"
root="$stage/$name"
mkdir -p "$root/scripts" "$root/Device" "$root/out/device"
for file in README.md THIRD_PARTY_NOTICES.md resize-apfs; do cp "$file" "$root/"; done
if [[ -f LICENSE ]]; then cp LICENSE "$root/"; fi
for script in build-overlay.py extract-binpack.py hfs-root-ownership.py audit-overlay.py boot-device.sh; do
  cp "scripts/$script" "$root/scripts/"
done
cp Device/upstream.lock.json Device/dev.omarchy.resize-apfs.plist "$root/Device/"
cp Device/README.md "$root/Device/"
for file in ResizeAPFS.app resize-helper resize-overlay-entry manifest.json; do
  ditto "out/device/$file" "$root/out/device/$file"
done
chmod +x "$root/resize-apfs" "$root/scripts/boot-device.sh"
python3 - "$root" <<'PY'
import hashlib,json,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1]); payload=root/'out/device'
manifest=json.loads((payload/'manifest.json').read_text())
for name,expected in manifest['files'].items():
    assert hashlib.sha256((payload/name).read_bytes()).hexdigest()==expected['sha256'], name
assert not list(root.rglob('*.mobileprovision')), 'Unexpected provisioning profile'
subprocess.run(['codesign','--verify','--deep','--strict',str(payload/'ResizeAPFS.app')],check=True)
sig=subprocess.run(['codesign','-dvv',str(payload/'ResizeAPFS.app')],capture_output=True,text=True,check=True).stderr
assert 'TeamIdentifier=not set' in sig and 'Authority=' not in sig, 'Unexpected developer identity'
files=sorted(p for p in root.rglob('*') if p.is_file())
(root/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(root)}\n' for p in files))
PY
python3 scripts/check-release.py --release-dir "$root"
zip="$PWD/out/releases/$name.zip"
[[ ! -e "$zip" ]] || { echo "Already exists: $zip" >&2; exit 1; }
ditto -c -k --keepParent --norsrc "$root" "$zip"
(cd out/releases && shasum -a 256 "$name.zip" > "$name.zip.sha256")
echo "Created $zip"
