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
its bundle identifier is `org.orchardlinux.resize-apfs`. Overlay SSH, telnet and debug
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

`scripts/checkra1n_route.py` copies `out/device-ios12/ResizeAPFS.app` and
`out/device-ios12/resize-helper` to `/private/var/ResizeAPFS` (root-owned, mode 755)
over checkra1n's SSH server, for one session only. On the device it uses only
`sh`, `mkdir`, `cat`, `chmod`, `rm` and `kill`.

Nothing goes to the system partition. A stock checkra1n boot mounts the system snapshot
read-only (`mount -uw /` fails with EBUSY), and making it writable means checkra1n's
"Install Cydia", which renames the snapshot: the session never asks for that. The app is
registered as an unsandboxed system app from the data partition, as checkra1n 0.12.4
registers its own loader on every boot: its post-mount hook runs
`/binpack/usr/bin/uicache --path /var/binpack/Applications/loader.app/`, with the loader
image mounted at `/var/binpack`. checkra1n's kernel patches let ad-hoc signed binaries run
from any path. Earlier releases used `/Applications/ResizeAPFS.app` and
`/var/root/ResizeAPFS/session` (only on a writable system partition); the route removes
leftovers from there too. The iOS 12-14 helper must accept:

- `--register-app PATH` / `--unregister-app PATH`: add the app to, or remove it from, the
  home screen (what `uicache` does), exit 0 on success. PATH must be an app bundle directly
  in `/private/var/ResizeAPFS`. Unregistering quits a running app
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
use the system's. The helper's second search path is `/private/var/ResizeAPFS/ResizeAPFS.app/Frameworks`:
on iOS 12.0-12.1 every helper command needs the app installed, which the route guarantees by
copying the app before the first helper command and removing it after the last.

## Without DFU

One app, installed with the user's Apple ID: the official [Dopamine](https://github.com/opa334/Dopamine)
release with Resize APFS in it. On the device it shows only Resize APFS.

### What is pinned, and what we add

`scripts/tools.py` pins `Dopamine.ipa` (3.0.13) by URL, size and SHA-256; the launcher downloads
it into Orchard's cache. Nothing of Dopamine is rebuilt, patched in its code or removed.
`scripts/embed.py` changes three things on the user's computer, before signing:

- the executable loads one more library, `Frameworks/ResizeAccess.dylib` (a load command added
  in the unused space after the existing ones);
- `Info.plist` loses Dopamine's scene configuration, so its app delegate makes no window, and
  takes the name, icon, launch screen and fonts of Resize APFS;
- the Resize APFS resources and `resize-helper.payload` are added to the bundle.

`ResizeAccess.dylib` (`scripts/build-device.sh`, in `out/device/access`) is the app's own
interface, the same sources as `ResizeAPFS.app` without `AppDelegate.swift`, plus
`Access/AccessBridge.m`. All it uses of Dopamine is in `Access/DopamineInterface.h`: three
classes, eight methods and one setting, looked up by name at run time. `embed.py` refuses a
Dopamine release whose executable lacks one of those names, and a test keeps its list and the
header the same.

Dopamine's own files all stay, its image catalog too (its code draws from it); the app icon
comes from loose files. Dopamine's app delegate answers for scenes, so iOS gives the app a
scene even without a scene configuration; the Resize APFS window joins that scene.

**Moving to a newer Dopamine:** [docs/updating-dopamine.md](../docs/updating-dopamine.md) has
the steps, what we depend on and what to do when something changed.

### On the device

`App/StorageAccess.swift` runs when the app opens:

1. Access is there (`isJailbroken`): go on to 3.
2. Otherwise the app shows **Storage access**: what will happen, and **Continue**. Nothing is
   triggered before that. Then the same page stays up with a spinner while Dopamine's
   `DOJailbreaker` runs (`runWithError:…`, then `finalize`, which restarts the screen). No
   package manager is installed: that is a choice of Dopamine's interface, which never runs. No
   terminal password is asked for (`NO_PASSWORD_PROMPT`, for the setup script of the files
   Dopamine unpacks on a first run), and those files hold no SSH server. They do give the
   user `mobile`, who may `sudo`, the well-known password `alpine`: the helper replaces that
   default by a random one when it starts (`TerminalPassword`), and leaves a password the user
   chose alone. Dopamine's logo for
   the screen restart is switched off (`bootlogoEnabled`).

   Some devices (an iPad (6th generation) on iPadOS 17.7 for one) first need their screen
   restarted once (Dopamine's "contiguous mapping workaround"). Nothing can open the app again
   after that restart, and Dopamine holds what the restart was for only about 20 seconds: the
   page's notice says to reopen the app within 20 seconds. The app leaves a note before that
   restart (`restarted` and the time); opened again within two minutes, it goes on by itself
   with the spinner page.

   An attempt that fails, that the device did not survive, or whose first screen restart was
   not used in time is remembered: the next launch shows **Couldn't get storage access**, the
   same notice and **Try again** instead of trying again by itself.
3. As root and outside the sandbox (`runAsRoot:` and `runUnsandboxed:`), the app puts the helper
   at `/var/jb/usr/libexec/resize-helper` and its launch daemon at
   `/var/jb/Library/LaunchDaemons/org.orchardlinux.resize-apfs.installed-helper.plist`, unless both are there
   unchanged. The helper must be inside the jailbreak root: launchd may not start programs
   from the data partition on iOS 15 and later. Right after obtaining access this happens
   before the screen restart, which then starts the daemon (Dopamine loads that folder's
   daemons with every screen restart).
4. The helper keeps opening the app until the app has connected: a device on its lock screen
   starts the app's process without showing it. Where access is there but no helper is serving
   (access from before the helper was in place), the app restarts the screen once to start it.
5. The app reads the helper's token and connects to its socket as root, then uses the open
   connection as usual. The helper runs with `--ipc-dir /private/var/ResizeAPFS/run --embedded
   IDENTIFIER PROCESS`: it accepts only root callers and opens the app by its bundle identifier.
   Not `/var/run`: the helper starts early in the screen restart, before iOS has set that up.

Rules the app keeps, each learned on an iPhone XR with iOS 18.3.2:

- **Privileged blocks run one at a time** and only read and write files or open the socket.
  Root is a state of the whole process; a second thread entering or leaving it ends it under
  the first. The app starts no program.
- **Nothing is kept in UserDefaults.** Obtaining access moves the process's home folder to
  root's. The last attempt (`attempt`) and a step log (`access.log`) are files in the app's
  `Library/Application Support/ResizeAPFS`, whose path is taken at launch. The log is the way
  to see what happened on a device: `xcrun devicectl device copy from --domain-type
  appDataContainer --domain-identifier IDENTIFIER --source "Library/Application Support/ResizeAPFS"`.

The helper travels in the bundle with `RESIZE-APFS-HELPER\n` in front of it: signing the app
with an Apple ID re-signs every program in it, which would cost the helper its entitlements.

### Signing and installing

The launcher asks the user to confirm Developer Mode is on. On a Mac whose Xcode is signed in,
`scripts/xcode_signing.py` signs the app with that account: Xcode builds a one-file stub app
with automatic signing for the connected device (registering it and making the profile), the
stub's profile, entitlements and certificate sign the app as `org.orchardlinux.resize-apfs.<team>`, and
`devicectl` installs it. Otherwise `scripts/sideload.py` signs and installs it with the pinned
xtool (2.0.0-beta.2; AppImage on Linux, notarized app on macOS, run with `XTL_CLI=1`):
`xtool auth login` once, in the user's terminal, then `xtool install --usb --udid`, which
registers the device, makes the App ID (`XTL-<account>.com.opa334.Dopamine`, the same on every
signing) and profile, signs and installs. Both identifiers are the ones earlier releases
signed the plain Dopamine with, so the app replaces that one in place. The expiry is kept in
Orchard's cache; a still-valid copy of the same app is not signed again (on a Mac, devicectl
also confirms it is still installed). Signing happens only on the user's computer with their
account; releases never contain anything team-signed.
