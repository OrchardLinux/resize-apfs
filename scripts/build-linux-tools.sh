#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Linux ] || { echo 'Build these tools on Linux.' >&2; exit 1; }
case $(uname -m) in
  x86_64) arch=x86_64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo 'Supported Linux architectures: x86_64 and arm64.' >&2; exit 1 ;;
esac
root=$PWD
out="$root/out/host-tools/linux-$arch"
mkdir -p "$out"
cd third_party/libdmg-hfsplus
hfs_sources='hfs/btree.c hfs/catalog.c hfs/extents.c hfs/xattr.c hfs/fastunicodecompare.c hfs/flatfile.c hfs/hfslib.c hfs/rawfile.c hfs/utility.c hfs/volume.c hfs/hfscompress.c'
dmg_sources='dmg/adc.c dmg/base64.c dmg/checksum.c dmg/dmgfile.c dmg/dmglib.c dmg/filevault.c dmg/io.c dmg/partition.c dmg/resources.c dmg/udif.c'
# Dynamic libc/zlib linkage; no OpenSSL/FileVault dependency.
# shellcheck disable=SC2086
${CC:-cc} -O2 -fcommon -Iincludes common/abstractfile.c $hfs_sources hfs/hfs.c -lz -o "$out/hfsplus"
# shellcheck disable=SC2086
${CC:-cc} -O2 -fcommon -Iincludes common/abstractfile.c $hfs_sources $dmg_sources dmg/dmg.c -lz -o "$out/dmg"
${STRIP:-strip} "$out/hfsplus" "$out/dmg"
chmod 755 "$out/hfsplus" "$out/dmg"
printf 'Built Linux tools: %s\n' "$out"
