#!/bin/bash
# The iOS 12-14 payload for scripts/checkra1n_route.py: out/device-ios12/ResizeAPFS.app
# and out/device-ios12/resize-helper. Current Xcode only accepts iOS 15+ deployment
# targets, so everything is compiled with swiftc/clang for arm64-apple-ios12.0, which
# also makes the compiler reject any API newer than iOS 12.
#
# Swift runtime: iOS 12.2 and later have it in /usr/lib/swift; iOS 12.0 and 12.1 do
# not. As Xcode does for apps, the app bundles Apple's back-deployment runtime
# (toolchain usr/lib/swift-5.0/iphoneos) in ResizeAPFS.app/Frameworks, searched after
# /usr/lib/swift, so the system copy wins wherever it exists. The checkra1n route
# copies only the helper file; it always installs the app first and removes it last,
# so the helper searches the installed app's Frameworks second.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ldid >/dev/null || { echo 'ldid is required for local ad-hoc jailbreak signing.' >&2; exit 1; }
out=out/device-ios12
build=.work/device-ios12
rm -rf "$out" "$build"
mkdir -p "$out" "$build"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
target=arm64-apple-ios12.0
swiftc() { xcrun --sdk iphoneos swiftc -target "$target" -sdk "$sdk" -swift-version 5 -O "$@"; }

xcrun --sdk iphoneos clang -target "$target" -isysroot "$sdk" -Os \
  -ISources/NativeSystem/include -c Sources/NativeSystem/NativeSystem.c -o "$build/NativeSystem.o"
swiftc -parse-as-library -emit-library -static -emit-module -module-name ResizeCore \
  -emit-module-path "$build/ResizeCore.swiftmodule" Sources/ResizeCore/*.swift -o "$build/libResizeCore.a"
swiftc -parse-as-library -emit-library -static -emit-module -module-name ResizeDevice \
  -emit-module-path "$build/ResizeDevice.swiftmodule" -I "$build" -I Sources/NativeSystem/include \
  Sources/ResizeDevice/*.swift -o "$build/libResizeDevice.a"
swiftc -I "$build" -I Sources/NativeSystem/include -L "$build" -lResizeDevice -lResizeCore \
  "$build/NativeSystem.o" Sources/ResizeHelper/main.swift \
  -Xlinker -rpath -Xlinker /Applications/ResizeAPFS.app/Frameworks -o "$out/resize-helper"

app="$out/ResizeAPFS.app"
mkdir -p "$app"
swiftc -I "$build" -L "$build" -lResizeCore App/*.swift \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks -o "$app/ResizeAPFS"
cp App/Info.plist "$app/Info.plist"
plutil -replace CFBundleIdentifier -string dev.omarchy.resize-apfs "$app/Info.plist"
plutil -replace CFBundleExecutable -string ResizeAPFS "$app/Info.plist"
plutil -replace CFBundleName -string ResizeAPFS "$app/Info.plist"
plutil -replace MinimumOSVersion -string 12.0 "$app/Info.plist"
plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$app/Info.plist"
plutil -replace UIDeviceFamily -json '[1,2]' "$app/Info.plist"
plutil -replace UIRequiredDeviceCapabilities -json '["arm64"]' "$app/Info.plist"
xcrun actool App/Assets.xcassets --compile "$app" --platform iphoneos --minimum-deployment-target 12.0 \
  --app-icon AppIcon --target-device iphone --target-device ipad \
  --output-partial-info-plist "$build/assets.plist" >/dev/null
for key in CFBundleIcons 'CFBundleIcons~ipad'; do
  plutil -replace "$key" -xml "$(plutil -extract "$key" xml1 -o - "$build/assets.plist")" "$app/Info.plist"
done
xcrun ibtool --minimum-deployment-target 12.0 --target-device iphone --target-device ipad \
  --compile "$app/LaunchScreen.storyboardc" App/Launch/LaunchScreen.storyboard
plutil -lint "$app/Info.plist" >/dev/null

# Bundle the back-deployment runtime the binaries need, with everything it needs itself.
runtime="$(dirname "$(dirname "$(xcrun --find swiftc)")")/lib/swift-5.0/iphoneos"
[[ -f "$runtime/libswiftCore.dylib" ]] || { echo "No Swift back-deployment runtime at $runtime." >&2; exit 1; }
mkdir -p "$app/Frameworks"
rpath_libs() { xcrun otool -L "$1" | awk '/@rpath\/libswift.*\.dylib/ {sub("@rpath/", "", $1); print $1}'; }
pending=$( { rpath_libs "$app/ResizeAPFS"; rpath_libs "$out/resize-helper"; } | sort -u)
while [[ -n "$pending" ]]; do
  next=""
  for lib in $pending; do
    [[ -f "$app/Frameworks/$lib" || ! -f "$runtime/$lib" ]] && continue
    # Bitcode is not used at runtime; Xcode strips it the same way when embedding.
    xcrun bitcode_strip -r "$runtime/$lib" -o "$app/Frameworks/$lib"
    next+=" $(rpath_libs "$app/Frameworks/$lib")"
  done
  pending=$(echo $next | tr ' ' '\n' | sort -u)
done
# Every runtime library loaded unconditionally must be bundled; weak ones may be missing.
strong_libs() { xcrun otool -l "$1" | awk '/cmd LC_LOAD_DYLIB/ {strong=1} /cmd LC_LOAD_WEAK_DYLIB/ {strong=0} /name @rpath\/libswift/ && strong {sub("@rpath/", "", $2); print $2}'; }
for binary in "$app/ResizeAPFS" "$out/resize-helper" "$app"/Frameworks/*.dylib; do
  for lib in $(strong_libs "$binary"); do
    [[ -f "$app/Frameworks/$lib" ]] || { echo "$binary needs $lib, which iOS 12.0 lacks and which is not bundled." >&2; exit 1; }
  done
done
for binary in "$app/ResizeAPFS" "$out/resize-helper"; do
  first=$(xcrun otool -l "$binary" | awk '/cmd LC_RPATH/ {getline; getline; print $2; exit}')
  [[ "$first" == /usr/lib/swift ]] || { echo "$binary must search /usr/lib/swift first, not $first." >&2; exit 1; }
done

# Remove linker debug maps/object paths before signing (they can expose the builder's home).
for binary in "$app/ResizeAPFS" "$out/resize-helper"; do xcrun --sdk iphoneos strip -S "$binary"; done
for lib in "$app"/Frameworks/*.dylib; do codesign --force --sign - --timestamp=none "$lib"; done
codesign --force --sign - --timestamp=none --generate-entitlement-der \
  --entitlements Device/app.entitlements.plist "$app"
codesign --verify --deep --strict "$app"
ldid -SDevice/helper-ios12.entitlements.plist "$out/resize-helper"
for binary in "$app/ResizeAPFS" "$out/resize-helper"; do
  minos=$(xcrun vtool -show-build "$binary" | awk '/minos/ {print $2}')
  [[ "$minos" == 12.0 ]] || { echo "$binary is built for iOS $minos, not 12.0." >&2; exit 1; }
done
python3 - <<'PY'
import hashlib,json,pathlib
root=pathlib.Path('out/device-ios12')
files=[p for p in root.rglob('*') if p.is_file() and p.name!='manifest.json']
manifest={'signing':'ad-hoc','minimumOS':'12.0','architecture':'arm64',
          'files':{str(p.relative_to(root)):{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),
                   'bytes':p.stat().st_size,'mode':p.stat().st_mode & 0o777} for p in files}}
(root/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Built iOS 12-14 payload: out/device-ios12/')
PY
