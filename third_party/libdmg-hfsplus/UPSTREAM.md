# libdmg-hfsplus

Source: https://github.com/planetbeing/libdmg-hfsplus
Commit: `7ac55ec64c96f7800d9818ce64c79670e7f02b67`
License: GPL-3.0; see LICENSE and individual file notices.

Local fixes:
- Empty B-tree lookups return no record instead of interpreting the header node.
- Freed B-tree nodes are erased.
- Partitionless UDIF images declare their actual sector count.

The build uses only the HFS/DMG code and zlib, with FileVault encryption disabled.
Build instructions: `scripts/build-linux-tools.sh`. The resulting programs run as
separate host utilities; they are not linked into the iOS app or helper.
