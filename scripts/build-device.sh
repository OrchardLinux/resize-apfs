#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ldid >/dev/null || { echo 'ldid is required for local ad-hoc jailbreak signing.' >&2; exit 1; }
mkdir -p out/device .work/device-build
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
target=arm64-apple-ios16.0
# Build unsigned; apply ad-hoc signatures after stripping debug metadata.
xcodebuild -project ResizeAPFS.xcodeproj -scheme ResizeAPFS -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath .deviceData \
  -jobs 2 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= build
products="$PWD/.deviceData/Build/Products/Release-iphoneos"
build="$PWD/.work/device-build"
xcrun --sdk iphoneos clang -target "$target" -isysroot "$sdk" -Os \
  -ISources/NativeSystem/include -c Sources/NativeSystem/NativeSystem.c -o "$build/NativeSystem.o"
xcrun --sdk iphoneos swiftc -target "$target" -sdk "$sdk" -swift-version 5 -O \
  -parse-as-library -emit-library -static -emit-module -module-name ResizeDevice \
  -emit-module-path "$build/ResizeDevice.swiftmodule" -I Sources/NativeSystem/include \
  -F "$products" -framework ResizeCore Sources/ResizeDevice/*.swift -o "$build/libResizeDevice.a"
xcrun --sdk iphoneos swiftc -target "$target" -sdk "$sdk" -swift-version 5 -O \
  -I "$build" -I Sources/NativeSystem/include -L "$build" -lResizeDevice \
  -F "$products" -framework ResizeCore "$build/NativeSystem.o" Sources/ResizeHelper/main.swift \
  -Xlinker -rpath -Xlinker /cores/binpack/usr/lib/swift -o out/device/resize-helper
xcrun --sdk iphoneos clang -target "$target" -isysroot "$sdk" -Os \
  Device/overlay-entry.c -o out/device/resize-overlay-entry
ditto "$products/ResizeAPFS.app" out/device/ResizeAPFS.app
# Remove linker debug maps/object paths before signing. These can expose the
# builder's home directory even in optimized Release binaries.
for binary in out/device/ResizeAPFS.app/ResizeAPFS out/device/resize-helper out/device/resize-overlay-entry; do
  xcrun --sdk iphoneos strip -S "$binary"
done
# Sign the app bundle and its resource envelope with the ad-hoc identity '-'.
codesign --force --sign - --timestamp=none --generate-entitlement-der \
  --entitlements Device/app.entitlements.plist out/device/ResizeAPFS.app
codesign --verify --deep --strict out/device/ResizeAPFS.app
ldid -SDevice/helper.entitlements.plist out/device/resize-helper
ldid -SDevice/helper.entitlements.plist out/device/resize-overlay-entry
if find out/device/ResizeAPFS.app -name '*.mobileprovision' | grep -q .; then
  echo 'Unexpected provisioning profile in the release payload.' >&2; exit 1
fi
python3 - <<'PY'
import hashlib,json,pathlib,subprocess
root=pathlib.Path('out/device')
files=[p for p in root.rglob('*') if p.is_file() and p.name!='manifest.json']
manifest={'signing':'ad-hoc','minimumOS':'16.0','architecture':'arm64',
          'files':{str(p.relative_to(root)):{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),
                   'bytes':p.stat().st_size,'mode':p.stat().st_mode & 0o777} for p in files}}
(root/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Built device payload: out/device/')
PY
