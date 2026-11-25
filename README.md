# Resize APFS

Resize your iPhone or iPad’s APFS storage to make room for Linux. A native app
handles APFS resizing, partition-table updates and readback verification. You can
leave the released space unallocated or create an unformatted Linux partition, and
erase Linux partitions after APFS to give their space back. On iOS 12 to 14 it can
also remove the `orig-fs` snapshot that keeps APFS from shrinking further.

**Experimental. Back up your device first. Storage changes can cause data loss.**

<p>
  <img src="docs/screenshots/storage-overview.png" alt="Storage overview showing APFS, Linux and unallocated space on iPad" width="45%">
  <img src="docs/screenshots/adjust-size.png" alt="Adjust size screen with target APFS size and Linux partition options" width="45%">
</p>

## Requirements

- An iPhone, iPad or iPod touch with a checkm8 chip (A8 to A11) on iOS/iPadOS 15 or later,
  or any checkm8 device (A7 to A11) on iOS 12 to 14. Experimental, without DFU: a device
  [Dopamine](https://github.com/opa334/Dopamine) supports (A8 to A13 on iOS 15.0-18.7.1 and
  26.0-26.0.1, A14 and later on iOS 15.0-17.3.1), with an Apple ID to sign Dopamine.
- Linux (x86_64 or ARM64, glibc 2.35+) or macOS (Intel or Apple Silicon).
- Python 3.9 or later and a USB connection to the device.

The launcher downloads the jailbreak it needs on first use, pinned by size and checksum:
[palera1n 3.0.0 beta 4](https://github.com/palera1n/palera1n/releases/tag/v3.0.0-beta.4)
for iOS 15 and later, [checkra1n 0.12.4](https://checkra.in/releases/0.12.4-beta) for
iOS 12 to 14, [Dopamine 3.0.13](https://github.com/opa334/Dopamine/releases/tag/3.0.13) and
[xtool 2.0.0-beta.2](https://github.com/xtool-org/xtool/releases/tag/2.0.0-beta.2) for the route without DFU. They are kept in Orchard's cache (`~/Library/Caches/orchard2` on macOS,
`~/.cache/orchard2` on Linux), shared with the Orchard installer. To use your own build
instead, set `PALERA1N`, `CHECKRA1N`, `DOPAMINE` or `XTOOL` to its path. On Apple Silicon, checkra1n needs
Rosetta. On Linux, the iOS 12-14 and Dopamine routes need the `usbmuxd` service.

Tested on hardware:

- iPad (6th generation, Wi-Fi / J71b), iPadOS 17.7.11: shrinking and growing.
- iPhone X (GSM / d221), iOS 16.7, from a Linux host: shrinking, the released space
  left unallocated ([#4](https://github.com/OrchardLinux/resize-apfs/issues/4)).
- iPad mini 4 (Wi-Fi / J96), iPadOS 15.8.3, palera1n 3.0.0 beta 3 from a Linux host:
  shrinking and creating a Linux partition
  ([#5](https://github.com/OrchardLinux/resize-apfs/pull/5)).
- iPod touch 6 (N102), iOS 12.4, checkra1n from macOS on Apple Silicon: removing a Linux
  partition, growing APFS back (after one restart) and shrinking again
  ([#7](https://github.com/OrchardLinux/resize-apfs/pull/7)).

Other devices and iOS versions are untested.

## Use

> [!IMPORTANT]
> **Boot tips**
> - **Before DFU:** close browsers that may use WebUSB. In Chrome, you can disable
>   USB access at `chrome://settings/content/usbDevices`.
> - **Stuck at the Apple logo after the boot starts?** Briefly disconnect the cable
>   from the device, then reconnect it.
> - **The boot fails and the device returns to iOS on its own?** Enter DFU and run
>   `./resize-apfs boot` again; it often takes a few tries. The end of the tool's log
>   is shown with the failure.

1. Back up your device.
2. Download the release ZIP from [GitHub Releases](https://github.com/OrchardLinux/resize-apfs/releases) and unzip it.
3. Open Terminal in the extracted folder and run:

   ```sh
   ./resize-apfs boot
   ```

   The launcher asks which iOS version the device runs (Settings > General > About;
   `--ios 15` or `--ios 12` skips the question), downloads palera1n or checkra1n,
   and starts it. Put the device in DFU mode when asked. The tool's own output goes
   to `.work/palera1n.log` or `.work/checkra1n.log`, shown only if the boot fails.

   On iOS 12 to 14 the launcher then copies Resize APFS to the device over the USB
   cable. When you are done in the app, press Enter in the terminal and it removes
   the app again.

4. Wait for iOS/iPadOS to finish starting normally, then unlock your device.
   Resize APFS opens by itself. If it doesn't, open it from the Home Screen.
5. Choose **Adjust size**, enter your target, then review and confirm the changes.
6. Wait for **Completed and verified** before restarting the device.

Booting loads the utility; it does not automatically resize anything. On Linux,
only starting palera1n or checkra1n may prompt for sudo; image preparation does not
require root.

## While resizing

Closing the app does not stop the operation. Reopen it to check the same operation.
Do not restart the device or run another storage tool while it is working.

Large shrinks run in steps (**Step 2 of 5**). To shrink, APFS moves everything
stored past the new end and holds storage while it does, so a single large call
can freeze iOS long enough for iOS to restart itself. Each step moves only a limited
amount of data and is verified before the next one starts. The step count is an
estimate and can change while the shrink runs.

Progress shows observed status, not an estimated percentage. **Status unavailable**
means confirmation is missing—not that the resize failed. Do not retry or reboot
solely because status is unavailable. If an operation stops with an error, inspect
the reported layout before attempting another change.

## How it works

The privileged helper calls Apple’s APFS framework already installed on the
device. It coordinates APFS and GPT changes and verifies the resulting layout.
Creating a Linux partition does not format it or install Linux.

On iOS 15 and later, palera1n boots iOS with Resize APFS in a read-only overlay;
on iOS 12 to 14, checkra1n boots iOS and the launcher copies the app in over SSH
through the USB cable for one session, then removes it. On both, the system partition
stays read-only and unchanged; nothing like checkra1n's "Install Cydia" is needed. Neither palera1n nor
checkra1n is part of the release: the launcher downloads the pinned version.

No Apple framework or firmware is bundled.

Without DFU (`./resize-apfs boot --dopamine`), the launcher asks you to turn on Developer
Mode, then signs the downloaded Dopamine with your Apple ID and installs it, after one
confirmation. It uses [xtool](https://github.com/xtool-org/xtool) (downloaded like the
jailbreaks), on Linux and macOS: the first time, xtool asks you to sign in (Apple ID, password,
two-factor code) and keeps the session. A free Apple ID signs Dopamine for 7 days; the launcher
signs it again when that runs out. Before Dopamine opens the first time, trust your Apple ID on
the device (Settings > General > VPN & Device Management). You open Dopamine and tap Jailbreak;
the launcher then copies the app in over the SSH server it adds to Dopamine's bootstrap, through
the USB cable for one session, as on iOS 12 to 14, and removes it afterwards. After every
restart of the device, tap Jailbreak again before the next session.

Apple's sign-in needs device-identity data ("anisette"), which xtool gets from the SideStore
project's Omnisette server, as free sideloading tools do; your password and two-factor code
go only to Apple.

## Development

Open `ResizeAPFS.xcodeproj` (it builds for iOS 15 and later), or run an existing
simulator with:

```sh
./scripts/run-simulator.sh
```

Simulator builds use synthetic storage. Run host tests with `swift test -j 2`.
See [Device/README.md](Device/README.md) for backend, overlay and build details.

## Release builds

The release workflow runs only for `v*` tags or manual requests. One macOS job
builds the app; small Linux jobs build host tools and assemble the release. Tagged builds create draft releases. Manual builds in private repositories
also retain the ZIP and checksum in a draft release; workflow artifacts expire
after two days, but release assets do not use that expiry.

Public builds include GitHub provenance attestations and a Sigstore bundle.
Private builds skip attestation. To verify a public download with the GitHub CLI:

```sh
gh attestation verify ResizeAPFS-v0.1.0.zip --repo OrchardLinux/resize-apfs
```

To build and package locally:

```sh
./scripts/build-device.sh
./scripts/build-device-ios12.sh   # the iOS 12-14 app and helper (Xcode can't target iOS 12)
./scripts/package-release.sh preview
```

For complete Linux support, also build `scripts/build-linux-tools.sh` on Linux
x86_64 and ARM64 and collect both `out/host-tools/linux-*` directories before
packaging with `--require-linux-tools`. Linux tools need a C compiler and zlib
headers to build; release users receive the compiled tools and their source.

Output: `out/releases/ResizeAPFS-preview.zip`. The ZIP includes only our
payload and assembly scripts, not palera1n or an assembled overlay.

## License

[MIT](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md) for upstream credits and licenses.

## Credits

Built on prior work from [Hoolock Linux](https://github.com/HoolockLinux/docs)
and [palera1n](https://github.com/palera1n), including jbinit.
