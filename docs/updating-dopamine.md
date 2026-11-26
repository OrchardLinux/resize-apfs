# Updating the pinned Dopamine

The app installed without DFU is the official [Dopamine](https://github.com/opa334/Dopamine)
release with Resize APFS in it ([Device/README.md](../Device/README.md#without-dfu)). This
page is for moving to a newer Dopamine release.

**When to update:** when a newer Dopamine supports iOS versions or devices we want, or fixes
something we ran into. The pinned release keeps working as it is; nothing requires following
every release.

## What we depend on

### 1. What we call

Everything is declared in [`Access/DopamineInterface.h`](../Access/DopamineInterface.h) and
called only from [`Access/AccessBridge.m`](../Access/AccessBridge.m):

| Class | Used |
| --- | --- |
| `DOJailbreaker` | `contiguousMappingWorkaroundNeeded`, `applyContiguousMappingWorkaround`, `runWithError:didRemoveJailbreak:showLogs:`, `finalize` |
| `DOEnvironmentManager` | `sharedManager`, `isJailbroken`, `runAsRoot:`, `runUnsandboxed:` |
| `DOPreferenceManager` | `sharedManager`, `setPreferenceValue:forKey:` with the setting `bootlogoEnabled` |

`scripts/embed.py` lists the same names (`INTERFACE`, `SETTING`) and refuses a Dopamine
executable that lacks one, naming it. A test keeps that list and the header identical, and
another keeps the bridge from naming any other Dopamine class.

### 2. How we get into the app

`scripts/embed.py`, on the user's computer, before signing:

- adds one load command for `Frameworks/ResizeAccess.dylib` to the executable, in the unused
  space after the existing ones (refused with "no room" when there is none);
- removes `UIApplicationSceneManifest` from `Info.plist` and takes name, icon, launch screen,
  fonts and orientations from ours (`INFO_KEYS`);
- replaces Dopamine's launch screen where it keeps it (`*.lproj/LaunchScreen.storyboardc`);
- adds our resources. Dopamine's own files all stay, `Assets.car` included.

### 3. How Dopamine behaves

No test covers these. They are how Dopamine's own app works in 3.0.13; where to look in its
source is given for each.

| We rely on | In Dopamine's source |
| --- | --- |
| Without a scene configuration, Dopamine opens no window, and iOS still gives the app a scene | `Application/Dopamine/App Delegates/` |
| With no package manager chosen, none is installed | `DOBootstrapper installPackageManagers`, `DOUIManager enabledPackageManagers` |
| `bootlogoEnabled = NO` keeps its logo off the screen restart, and nothing is drawn | `DOEnvironmentManager updateBootLogo` |
| On a device's first run, the unpacked files' setup script asks for no terminal password when `NO_PASSWORD_PROMPT` is set, and the app's environment reaches that script | `prep_bootstrap.sh` in the app's `bootstrap_*.tar.zst`; `DOBootstrapper finalizeBootstrap`; `BaseBin/dopamine/src/main.m` sets the same |
| The files it unpacks hold no SSH server | `tar --zstd -tf bootstrap_*.tar.zst`, no `sshd` |
| After `runWithError:` succeeded, `runAsRoot:` and `runUnsandboxed:` work until `finalize` | `DOJailbreaker runWithError:`, `DOEnvironmentManager runAsRoot:` |
| Daemons in `/var/jb/Library/LaunchDaemons` start with every screen restart | `BaseBin/launchdhook/src/daemon_hook.m` |
| After the restart, the app is recognised by its bundle identifier and path | `BaseBin/libjailbreak/src/util.m`, `is_dopamine_app` |
| Its settings are the file `Library/Preferences/com.opa334.Dopamine.plist` in the app's folder | `DOPreferenceManager` |

## Steps

1. **Change the pin** in `scripts/tools.py`: `DOPAMINE_RELEASE` (the release's address) and
   in `DOPAMINE` the `size` and `sha256` of its `Dopamine.ipa`. Update the version in the
   comment above it, in this page and in `Device/README.md`, and the address and size in
   `Tests/ReleaseTests/test_dopamine_route.py`.

2. **Run the release tests:**

   ```sh
   python3 -m unittest discover -s Tests/ReleaseTests
   ```

3. **Check the real file** against layers 1 and 2. This downloads the new release into
   Orchard's cache and prepares the app without installing it:

   ```sh
   ./scripts/build-device.sh
   python3 - <<'EOF'
   import sys, tempfile
   sys.path.insert(0, 'scripts')
   import embed, tools
   with tempfile.TemporaryDirectory() as work:
       print(embed.prepared_ipa(tools.provide('dopamine'), work, 'out/device/access'))
   EOF
   ```

   An error names what no longer fits. A missing name: see "When something changed" below.

4. **Read Dopamine's changes** to the files in the table of layer 3, between the two
   releases. This is the only check of layer 3 before a device.

5. **Run it on a device, from a restarted device,** twice:
   - a device that never had access: open the app, expect **Getting storage access**, one
     screen restart, and after unlocking the storage overview, without opening the app by hand;
   - the same device after another restart: the same, faster.

   Package and install as a user would (`./scripts/package-release.sh preview`, then
   `./resize-apfs boot --no-dfu` in the unpacked ZIP).

6. **Read the app's log** whatever the outcome; it says which step was reached:

   ```sh
   xcrun devicectl device copy from --device UDID --domain-type appDataContainer \
     --domain-identifier IDENTIFIER --source "Library/Application Support/ResizeAPFS" \
     --destination ./resize-apfs-log
   ```

   `IDENTIFIER` is the installed app's (`xcrun devicectl device info apps --device UDID`).
   The device must be unlocked. A good run ends with `the helper is serving` and
   `helper connected`.

## When something changed

- **A name is missing** (step 2 or 3): find what replaced it in Dopamine's source, change
  `Access/DopamineInterface.h`, `Access/AccessBridge.m` and `INTERFACE` in `scripts/embed.py`
  together. Keep the bridge the only place that calls Dopamine.
- **"No room for another library":** the new executable has less unused space after its load
  commands. The alternative is replacing one of its own load commands' targets, which this
  project has not needed yet.
- **The app is black, or shows Dopamine's screen:** layer 3, first row. See how its app
  delegate and scene delegate start, and `EmbeddedApp.start` in `App/StorageAccess.swift`.
- **The app crashes while getting access:** pull its crash report (`idevicecrashreport -k`)
  and look for a Dopamine step that draws or reads a resource we replaced. That is how
  replacing `Assets.car` was found to break `updateBootLogo`.
- **Access is obtained but the storage overview never comes:** the log's `helper …` lines say
  whether the helper runs and what its folders hold. The helper has to be inside `/var/jb`
  and is started only by the screen restart.

## What not to do

- Do not copy Dopamine's source into this repository or rebuild it. The official file,
  checked by size and SHA-256, is the dependency.
- Do not start programs from the app, and do not run two privileged blocks at once
  ([Device/README.md](../Device/README.md#on-the-device) lists these rules).
- Do not call more of Dopamine than the header lists without adding it there and to
  `INTERFACE`.
