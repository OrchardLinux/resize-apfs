# Device backend and overlay

## Status

See the tested devices in the [README](../README.md#requirements). The iOS 12-14
route, erasing Linux partitions and removing the `orig-fs` snapshot have not run on
a device yet.

## Build and prepare

Developers need Xcode and `ldid`:

```sh
./scripts/build-device.sh
./scripts/package-release.sh preview
```

Release users run `./resize-apfs prepare` or `./resize-apfs boot` from the extracted
ZIP. The launcher downloads the pinned palera1n into Orchard's shared cache (or uses
the one `PALERA1N` names) and checks its version, overlay capability and embedded
filesystem layout. `upstream.lock.json` records
the original reference build, not a runtime whitelist.

The launcher extracts that binpack locally and replaces the stock loader app with
Resize APFS. The original boot hooks and daemon remain. The release ZIP contains
our payload, launcher, Linux host tools and their corresponding source.

The loader bundle retains the stock `palera1nLoader.app` path for boot compatibility;
its bundle identifier is `dev.omarchy.resize-apfs`. Overlay SSH, telnet and debug
shell listeners are disabled. Existing jailbreak services outside this overlay
are not removed or reconfigured.

Preparation modifies only generated image files. It does not contact a device.
Storage writes require a review and confirmation in the app; booting does not
change storage.

## Host image preparation

macOS uses the system image tools. Linux uses the bundled GPL-3.0 `dmg` and
`hfsplus` utilities; their complete source and build script accompany the ZIP.
No filesystem mounts or root privileges are needed to prepare images on Linux.
The backend validates UDIF geometry/CRCs, filesystem metadata, unique outer/inner
IDs, root ownership, executable modes, symlinks and every app resource's readback.

Linux-generated overlays have been hardware-tested through macOS palera1n.
Native Linux-host USB/DFU handling remains untested.

## Privileges and operation lifetime

The app runs as mobile. A separate root launchd helper serves protected local IPC
at `/var/run/resize-apfs/helper.sock`, with peer credentials, executable-path
validation and a rotating capability token. There is no TCP or arbitrary-shell
endpoint. This is not a security boundary against root or injection into the
trusted app on an already-compromised device.

Authorization, worker PID, operation state and original GPT snapshots are saved
under `/var/root/Library/ResizeAPFS/`. GPT snapshots are not user-data backups.
These files have no data protection (class D): the helper starts at boot and must read
them before anyone unlocks the device; they hold partition geometry and step state, no
user data, in a root-only folder. The helper still waits for the first unlock since boot
(MobileKeyBag `MKBDeviceUnlockedSinceBoot`) before it starts serving, because files from
earlier versions, its token and the app need it; it then moves older files to class D.
A completed and verified operation is history: it is reported once, while the layout is
still the one it produced, and never as an error after the layout changed later.
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

Growth also checks kernel-visible partition capacity. After the expanded GPT is
written and verified, the helper asks the kernel to read the partition table again
(`IOServiceRequestProbe` on disk0's partition scheme, else its media) and waits up to
10 seconds for the APFS partition device to report the new size. Each attempt (probe
results, size before and after) goes to the helper log and to `reprobe.log` in the
journal folder. If iOS still retains the old boundary, the operation can stop after
expanding GPT and explain that another boot may be needed. It never forces an unmount
or reboot.

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

## iOS 12-14 (checkra1n route)

`scripts/checkra1n_route.py` copies `out/device-ios12/ResizeAPFS.app` to
`/Applications` and `out/device-ios12/resize-helper` to `/var/root/ResizeAPFS/session`
over checkra1n's SSH server, for one session only. On the device it uses only
`sh`, `mkdir`, `cat`, `chmod`, `rm` and `kill`. The iOS 12-14 helper must accept:

- `--register-app PATH` / `--unregister-app PATH`: add the app to, or remove it from, the
  home screen (what `uicache` does), exit 0 on success. Unregistering quits a running app
  first: FrontBoard terminates it (`FBSSystemService`, entitlement
  `com.apple.multitasking.termination`), as the app switcher does, and the app is removed
  only once its process is gone and FrontBoard no longer reports one for it. Each wait has a
  10-second deadline; an app FrontBoard did not end is killed and waited for once more, and an
  app still running after that is not removed (exit 1). An app removed while it runs leaves a
  black screen the Home button does not leave.
- `--session --allow-writes --ui-path PATH`: serve the app in the foreground as on the
  palera1n route, trusting the app executable at PATH instead of the overlay's.
- `--operation-active`: exit 0 while a resize it started is still running, else 1.
- `--reprobe diskNsM` (testing only, not used by the route): ask the kernel to read the disk's
  GPT again and print the partition's size before and after; also appended to `reprobe.log`.
  Writes nothing to the disk.

`scripts/build-device-ios12.sh` builds both for iOS 12.0 and later (not yet part of a release).
iOS 12.0 and 12.1 have no Swift runtime, so the app bundles Apple's back-deployment runtime in
`ResizeAPFS.app/Frameworks`; both binaries search `/usr/lib/swift` first, so iOS 12.2 and later
use the system's. The helper's second search path is `/Applications/ResizeAPFS.app/Frameworks`:
on iOS 12.0-12.1 every helper command needs the app installed, which the route guarantees by
copying the app before the first helper command and removing it after the last.
