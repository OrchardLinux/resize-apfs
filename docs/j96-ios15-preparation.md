# iPad mini 4 (J96) on iOS 15

The app, framework and helper target iOS 15, so iPads whose last iOS is 15 (iPad
mini 4, iPad Air 2) can run Resize APFS. iOS 16-only SwiftUI has iOS 15
equivalents: `NavigationView` in stack style in place of `NavigationStack`, the
older call to hide the navigation bar, the large progress spinner and
interactive keyboard dismissal on scroll only from iOS 16 (the keyboard's Done
button works on both). The APFS resize logic, the private APFS ABI and the
metadata and minimum-size checks are unchanged.

## Device run (iPad5,1, iPadOS 15.8.3, 5–6 November 2026)

palera1n: the J96 reached Pongo reliably only with palera1n 3.0.0 beta 3 and a
real power-off plus cool-down before entering DFU. A plain
`palera1n --override-overlay` run with the earlier palera1n left the iPad in
recovery mode. `scripts/palera.py` recognises beta 3's pre-release banner
(`Palera1n beta 3.0.0`), so overlays can be prepared for it. An overlay is tied
to the palera1n binpack it was prepared with; rebuild it for beta 3:

    PALERA1N=<path>/palera1n-beta3 python3 scripts/build-overlay.py --enable-writes \
        --output out/j96-ios15-beta3-write.dmg

The command that booted it:
`sudo env -i PATH=/usr/bin:/bin LANG=C <palera1n> --cli --rootless --override-overlay <overlay> -d -n`.
Built images are not committed: they embed the palera1n binpack.

Outcome: the first shrink (5 Nov) was ended by an iPadOS watchdog reset after
91 s without a check-in. The panic showed the resize worker blocked in the
kernel with storage threads waiting on locks. The app detected the restart and
left the layout unchanged. A retry from the same overlay (6 Nov) completed: the
APFS container is 54.3 GB and a 73.7 GB Linux partition follows it. Verified
read-only from Linux: GPT entry 1 APFS LBA 6–13,256,840; entry 2 Linux
13,256,848–31,249,994; both GPT headers valid; APFS block count equals entry 1.
The cause of the first stall is still unknown.
