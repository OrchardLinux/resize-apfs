# J96 iOS 15 preparation — unvalidated device build

Base: ac1658923378dcb800523d7dcd45002fc2bc5862.
Branch: j96/ios15-readonly-prep.
Target: iPad5,1 / J96AP, last verified iOS 15.8.3.
The owner states the iPad was wiped and contains no user data to back up.
The owner explicitly authorizes pursuing APFS resizing and internal installation.
No device operation or storage mutation was performed by this preparation.

Changes: app/framework/helper deployment targets lowered to iOS 15; navigation
uses NavigationView; automatic scroll keyboard dismissal is guarded on iOS 16;
root navigation-bar hiding uses the older API; large progress-control sizing
removed. Storage mutation implementation and private APFS ABI are unchanged.
This is source preparation, not proof that the app compiles or the APIs work.

Validation: shell syntax, git diff whitespace, 41 Python release tests pass.
The owner reauthenticated GitHub. Build run 40460764485 in the owner fork at
48d0bc00901152930a026a45e6900e1a04f73d5b passed 28 Swift tests, 41 Python
release tests, the Xcode device build, signing checks and packaging. Artifact
12714187440 has SHA-256
f1f380100d9dd2119348d138631100d3f8ee2cb295c04fcf5dbe8b4a60aa086b.
Native iOS execution and the APFS shrink were later verified on the device (below).
The XPS still has neither Swift nor Xcode; builds use macOS GitHub Actions.

First device payload must be inspection-only (build-overlay.py without
--enable-writes), retaining the existing helper writes-disabled default.
First establish app/helper operation and validate read-only GPT/APFS inspection.
Do not remove ABI, metadata or minimum-size checks to make the device pass.
An empty/wiped user installation does not make its system GPT/APFS disposable.

## Device use (5–6 November 2026)

palera1n: J96 reaches Pongo reliably only with palera1n 3.0.0 beta 3 and a real
power-off plus cool-down before DFU (the J96 cold-start tooling, cold-probe.py
and live-probe.py, outside this repository). A plain `palera1n --override-overlay`
run left the iPad in recovery mode.

Changes for that, on this branch:
- `scripts/palera.py`: parse the pre-release banner `Palera1n beta 3.0.0`.
  The existing patterns rejected it, so beta 3 could not prepare overlays.
- `scripts/j96_cold_boot.py`: boot a prepared overlay through the cold-start
  procedure. Checks: overlay checksum, size and binpack against the selected
  palera1n (via boot_device.py); the exact palera1n executable hash; iOS 15
  device build; no network listeners; recovery mode refused; slide-to-power-off
  required; device identity re-checked after DFU. A write overlay needs
  `--allow-write`. The command is the proven one:
  `sudo env -i PATH=/usr/bin:/bin LANG=C <palera1n> --cli --rootless
  --override-overlay <overlay> -d -n`. Without `--boot` it only checks files.
- Tests: `Tests/ReleaseTests/test_j96_cold_boot.py` and a banner case in
  `test_universal_palera.py` (46 release tests pass).

An overlay is tied to the palera1n binpack it was prepared with. The 27 October
inspection overlay was built for another palera1n, so it is rejected for beta 3.
It was also inspection-only, which is why the app showed resizing as disabled.
Rebuild against beta 3:

    PALERA1N=<path>/palera1n-beta3 python3 scripts/build-overlay.py --enable-writes \
        --output out/j96-ios15-beta3-write.dmg
    python3 scripts/j96_cold_boot.py --overlay out/j96-ios15-beta3-write.dmg \
        --palera1n <path>/palera1n-beta3 --cold-probe <path>/cold-probe.py --allow-write --boot

Built images are not committed: they embed the palera1n binpack.

Outcome: the first shrink (5 Nov) was ended by an iPadOS watchdog reset after
91 s without a check-in. The panic showed the resize worker blocked in the kernel
with storage threads waiting on locks. The app detected the restart and left the
layout unchanged. A retry from the same overlay (6 Nov) completed: the APFS
container is 54.3 GB and a 73.7 GB Linux partition follows it. Verified read-only
from Linux: GPT entry 1 APFS LBA 6–13,256,840; entry 2 Linux 13,256,848–
31,249,994; both GPT headers valid; APFS block count equals entry 1. No watchdog
change was made; the cause of the first stall is still unknown.
