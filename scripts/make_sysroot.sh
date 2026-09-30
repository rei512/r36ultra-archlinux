#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the cross-compilation sysroot for the GUI programs (wvkbd and anything
# else built against the card's libraries): the rootfs tarball's own headers and
# libraries, with the packages from build/pkgs/gui on top - the same combination the
# card ends up with, so what links here runs there.
#
# Kept separate from build/gui_stage/rootfs, which is packed into the archive and must
# not carry the tarball's files.
set -euo pipefail

TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=$TOP/build/sysroot
PKGS=$TOP/build/pkgs/gui
ROOTFS_TAR=$TOP/build/ArchLinuxARM-aarch64-latest.tar.gz

rm -rf "$OUT"
mkdir -p "$OUT"

# 1) What the card already has (glib2, libdbus, openssl ... and their headers).
tar -xzf "$ROOTFS_TAR" -C "$OUT" ./usr/include ./usr/lib ./usr/share/pkgconfig

# 2) What the overlay adds or replaces (wayland, pango, cairo, glibc 2.43 ...).
PKG_EXCLUDE=(--exclude=.PKGINFO --exclude=.MTREE --exclude=.BUILDINFO --exclude=.INSTALL --exclude=.CHANGELOG)
for f in "$PKGS"/*.pkg.tar.xz; do
	tar --force-local -xpJf "$f" -C "$OUT" "${PKG_EXCLUDE[@]}"
done

echo "sysroot: $OUT ($(du -sh "$OUT" | cut -f1))"
echo "use with: CC=\"aarch64-linux-gnu-gcc --sysroot=$OUT\" PKG_CONFIG_SYSROOT_DIR=$OUT PKG_CONFIG_LIBDIR=$OUT/usr/lib/pkgconfig:$OUT/usr/share/pkgconfig"
