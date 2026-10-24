# Device backend and overlay

## Status

Hardware testing covers iPad (6th generation, Wi-Fi / J71b), iPadOS 17.7.11. The
CI-built release ZIP was prepared in Linux and booted through macOS palera1n.
Boot, app registration/launch, real storage inspection and a 64 GB → 60 GB APFS
shrink succeeded. Growth, Linux partition creation and other device/OS
combinations are not yet verified.

## Build and prepare

Developers need Xcode and `ldid`:

```sh
./scripts/build-device.sh
./scripts/package-release.sh preview
```

Release users run `./resize-apfs prepare` or `./resize-apfs boot` from the extracted
ZIP. palera1n 2.4+ must be installed separately. The launcher checks its version,
overlay capability and embedded filesystem layout. `upstream.lock.json` records
the original reference build, not a runtime whitelist.

The launcher extracts that binpack locally and replaces the stock loader app with
Resize APFS. The original boot hooks and daemon remain. The release ZIP contains
our payload, launcher, Linux host tools and their corresponding source.

The loader bundle retains the stock `palera1nLoader.app` path for boot compatibility;
its bundle identifier is `dev.omarchy.resize-apfs`. Overlay SSH, telnet and debug
shell listeners are disabled. Existing jailbreak services outside this overlay
are not removed or reconfigured.

Preparation modifies only generated image files. It does not contact a device.
Booting requires explicit confirmation, and storage writes require a separate
review and confirmation in the app.

## Host image preparation

macOS uses the system image tools. Linux uses the bundled GPL-3.0 `dmg` and
`hfsplus` utilities; their complete source and build script accompany the ZIP.
No filesystem mounts or root privileges are needed to prepare images on Linux.
The backend validates UDIF geometry/CRCs, filesystem metadata, unique outer/inner
IDs, root ownership, executable modes, symlinks and every app resource's readback.

Linux-generated images have completed the boot, inspection and shrink checks
above. Native Linux-host USB/DFU handling remains untested.

## Privileges and operation lifetime

The app runs as mobile. A separate root launchd helper serves protected local IPC
at `/var/run/resize-apfs/helper.sock`, with peer credentials, executable-path
validation and a rotating capability token. There is no TCP or arbitrary-shell
endpoint. This is not a security boundary against root or injection into the
trusted app on an already-compromised device.

Authorization, worker PID, operation state and original GPT snapshots are saved
under `/var/root/Library/ResizeAPFS/`. GPT snapshots are not user-data backups.
A gated child process executes resizing independently of the UI. Reopening the
app queries the existing operation; it does not repeat a start request. A helper
restart with an interrupted operation records an unknown outcome, not a retry.

Heartbeats observe the actual child and reuse an authenticated socket connection.
Blocking metadata reads run outside Swift's cooperative executor. Confirmation
older than 15 seconds displays **Status unavailable**, never fabricated activity
or an automatic retry. Device-wide freezes can still interrupt communication.

## Storage handling

Inspection validates both GPT copies and checksummed APFS metadata. Initially,
only a single APFS physical store on disk0 is supported. Unknown layouts are
refused rather than repaired.

The helper resolves `APFSContainerGetMinimalSize` and `APFSContainerResize` from
Apple's APFS framework already installed on the device. The private API ABI is
not a compatibility guarantee; unavailable or implausible sizing limits are
refused.

Shrinking changes APFS before GPT; growing expands GPT before APFS. The fenced
GPT writer updates backup then primary metadata, flushes and reads back, and
preserves the MBR and unrelated entries. Completion requires the requested APFS
size and GPT layout to match readback.

Growth also checks kernel-visible partition capacity. If iOS retains the old
boundary, the operation can stop after expanding GPT and explain that another
boot may be needed. It never forces an unmount or reboot.

Linux partition creation changes GPT only. It does not format, wipe, mount or
install Linux. Previously used space can still contain old bytes.

## Testing and signing

Host tests use disposable regular-file disks; host physical disks and the APFS
mutation API are refused. Simulator builds use synthetic storage. Neither proves
real-device APFS behavior or data integrity.

Binaries are ad-hoc signed. Release packaging checks signatures, file hashes and
package contents.
Generated overlays are audited read-only for root ownership, payload hashes,
configuration and disabled network listeners.
