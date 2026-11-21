# iOS 12-14 and checkra1n support

Older checkm8 devices whose final OS is iOS 12 (such as iPod touch 6 / N102 on
iOS 12.4) use checkra1n (rootful jailbreak with root SSH over USB) rather than
palera1n's iOS 15+ rootless overlay and SwiftUI app.

## Shared core and iOS 12 findings

`ResizeCore` (`APFSMetadata.swift`, `GPT.swift`, `Planner.swift`, `Storage.swift`)
and `NativeSystem` (`NativeSystem.c`) are shared unchanged in logic across both
iOS 15+ (palera1n) and iOS 12.4 (checkra1n):

- Apple's private `/System/Library/PrivateFrameworks/APFS.framework/APFS` on
  iOS 12.4 (`apfs-945.272.3`) exports the same C ABI used on iOS 15+:
  - `APFSContainerGetMinimalSize(const char *bsdName, uint64_t *outBytes)`
    -> `AppleAPFSUserClient` selector `0x22` -> `nx_get_minimal_size`.
  - `APFSContainerResize(const char *bsdName, uint64_t newSizeBytes)` and
    `APFSContainerResizeEx(const char *bsdName, uint64_t newSizeBytes, uint64_t *outMinBytes)`
    -> `AppleAPFSUserClient` selector `0x02` -> `AppleAPFSContainer::containerResize`
    -> `nx_resize`.
- iOS 12.2+ ships the Swift 5 ABI-stable standard library and Foundation under
  `/usr/lib/swift/`, but does **not** ship Swift Concurrency (`iOS 13+/15+`),
  `CryptoKit` (`iOS 13+`), or `FormatStyle` (`iOS 15+`). The shared code uses
  `CommonCrypto` (`CC_SHA256`) and `#available(iOS 15, *)` fallbacks so the
  same sources build cleanly for both `arm64-apple-ios15.0` and
  `arm64-apple-ios12.4`.
- On iOS 12.4, `nx_get_minimal_size` computes the physical block tidemark of
  every APFS snapshot across all volumes in the container and caps shrinkable
  space at or above the highest snapshot block. `NativeSystem` enumerates
  mounted volume snapshots read-only via `fs_snapshot_list` so the CLI reports
  any snapshot pinning the minimum size.

## Building

```sh
./scripts/build-device.sh --ios12-only
```

This builds, strips, and `ldid`-signs `out/device/resize-helper-ios12` with
`Device/helper.entitlements.plist` (targeting `arm64-apple-ios12.4` with rpath
`/usr/lib/swift`). A full `./scripts/build-device.sh` builds both the iOS 15+
palera1n payload and `out/device/resize-helper-ios12`.

## Usage over root SSH (checkra1n)

1. Boot the device with checkra1n (manual DFU, `checkra1n -c`).
2. Copy `out/device/resize-helper-ios12` to `/var/root/resize-helper-ios12`
   (or run `./resize-apfs checkra1n deploy --host root@127.0.0.1 --port <port>`).
3. Inspect layout, kernel minimum, and snapshots (read-only):
   ```sh
   /var/root/resize-helper-ios12 --layout
   ```
4. Dry-run a shrink plan (e.g. shrink iOS APFS container to 10 GiB, leaving the
   remainder unallocated for Linux):
   ```sh
   /var/root/resize-helper-ios12 --shrink-to 10
   ```
5. Apply with explicit confirmation:
   ```sh
   /var/root/resize-helper-ios12 --shrink-to 10 --yes
   ```
6. Reboot iOS and confirm it still boots before installing Linux into the
   unallocated trailing space.

Hardware verification on iPod touch 6 (N102, iOS 12.4, checkra1n 0.12.4) is
pending.
