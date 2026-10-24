#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
overlay="$PWD/out/resize-apfs-inspect.dmg"
boot=false
while (($#)); do
  case "$1" in
    --overlay) overlay=$2; shift 2 ;;
    --boot) boot=true; shift ;;
    *) echo 'Usage: scripts/boot-device.sh [--overlay FILE] [--boot]' >&2; exit 2 ;;
  esac
done
palera=$(command -v palera1n) || { echo 'palera1n is not in PATH' >&2; exit 1; }
python3 - "$overlay" "$palera" <<'PY'
import hashlib,json,pathlib,sys
image=pathlib.Path(sys.argv[1]); binary=pathlib.Path(sys.argv[2])
manifest=json.loads(image.with_suffix('.json').read_text())
assert hashlib.sha256(image.read_bytes()).hexdigest()==manifest['sha256'], 'Overlay differs from its manifest'
assert hashlib.sha256(binary.read_bytes()).hexdigest()==manifest['palera1n']['installedBinarySHA256'], 'palera1n does not match the prepared overlay. Run ./resize-apfs prepare with a supported installation.'
PY
if ! "$boot"; then
  printf 'Boot command: '; printf '%q ' "$palera" -l -o "$overlay"; printf '\n'
  echo 'Rerun with --boot to start palera1n.'
  exit 0
fi
echo 'Starting palera1n...'
exec "$palera" -l -o "$overlay"
