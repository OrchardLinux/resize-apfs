#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Select an existing iPad or iPhone. SIMULATOR_ID overrides selection.
# No simulators or runtimes are created or downloaded.
device=${SIMULATOR_ID:-$(xcrun simctl list devices available -j | python3 -c '
import json,sys
devices=[d for group in json.load(sys.stdin)["devices"].values() for d in group
         if d["name"].startswith(("iPad", "iPhone"))]
devices.sort(key=lambda d: (not d["name"].startswith("iPad"), d["state"]!="Booted"))
print(devices[0]["udid"] if devices else "Missing")
')}
mkdir -p .mock
service=$(python3 - <<'PY'
import json, urllib.request, urllib.error
try:
    with urllib.request.urlopen('http://127.0.0.1:8472/health', timeout=2) as response:
        state = json.load(response)
    if state.get('mode') != 'mock':
        raise SystemExit('Port 8472 is not the Resize APFS mock service; refusing to continue.')
    print('ready')
except urllib.error.HTTPError:
    raise SystemExit('Port 8472 is occupied by an unexpected service; refusing to start another.')
except (urllib.error.URLError, TimeoutError):
    print('missing')
PY
)
if [[ "$service" == missing ]]; then
  swift build -j 2 --product resize-mock
  nohup .build/debug/resize-mock --state "$PWD/.mock/state.json" > .mock/server.log 2>&1 < /dev/null &
  echo $! > .mock/server.pid
fi
state=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=sys.argv[1]; print(next((v["state"] for a in json.load(sys.stdin)["devices"].values() for v in a if v["udid"]==d), "Missing"))' "$device")
if [[ "$state" == Missing ]]; then echo 'Set SIMULATOR_ID to an existing simulator UUID.' >&2; exit 1; fi
if [[ "$state" != Booted ]]; then xcrun simctl boot "$device"; fi
xcrun simctl bootstatus "$device" -b
xcodebuild -project ResizeAPFS.xcodeproj -scheme ResizeAPFS -configuration Debug \
  -destination "platform=iOS Simulator,id=$device" -derivedDataPath .derivedData \
  -jobs 2 CODE_SIGNING_ALLOWED=NO build
xcrun simctl install "$device" .derivedData/Build/Products/Debug-iphonesimulator/ResizeAPFS.app
xcrun simctl launch "$device" dev.omarchy.resize-apfs
developer=$(xcode-select -p)
if [[ -d "$(dirname "$developer")/Applications/DeviceHub.app" ]]; then
  open -a "$(dirname "$developer")/Applications/DeviceHub.app" "devices://device/open?id=$device"
else
  open -a Simulator --args -CurrentDeviceUDID "$device"
fi
