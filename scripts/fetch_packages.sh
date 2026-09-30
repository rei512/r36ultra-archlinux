#!/bin/bash
# SPDX-License-Identifier: MIT
# Download everything the rootfs is built from into build/:
#   - the Arch Linux ARM aarch64 rootfs tarball, checked against its .md5
#   - the packages in rootfs/packages-wifi.txt and rootfs/packages-gui.txt with
#     their dependencies, checked against the repo db (fetch_pkgs.py)
# Dependencies the tarball already has are skipped. A listed package that the
# tarball also has is taken from the repo anyway (--refresh): the GUI packages
# are newer than the tarball and need e.g. its glibc and glib2 to be newer too.
set -euo pipefail

TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
B=$TOP/build
ROOTFS_TAR=$B/ArchLinuxARM-aarch64-latest.tar.gz
URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz

mkdir -p "$B/pkgs/gui"

if [ ! -s "$ROOTFS_TAR" ]; then
	curl -fL -o "$ROOTFS_TAR.part" "$URL"
	curl -fsL -o "$ROOTFS_TAR.md5" "$URL.md5"
	(cd "$B" && sed 's/\.tar\.gz$/.tar.gz.part/' ArchLinuxARM-aarch64-latest.tar.gz.md5 | md5sum -c -)
	mv "$ROOTFS_TAR.part" "$ROOTFS_TAR"
fi

# The packages the tarball has, from its pacman database.
INSTALLED=$B/pkgs/installed.txt
tar -xzOf "$ROOTFS_TAR" --wildcards './var/lib/pacman/local/*/desc' 2>/dev/null |
	awk '/^%NAME%$/ { getline; print }' | sort -u > "$INSTALLED"
echo "rootfs tarball: $(wc -l < "$INSTALLED") packages"

list() { grep -v -e '^#' -e '^$' "$1"; }

fetch() {	# fetch <out dir> <package list>
	local refresh
	refresh=$(comm -12 <(list "$2" | sort) "$INSTALLED")
	# --refresh takes every argument after it, so it goes last.
	python3 "$TOP/scripts/fetch_pkgs.py" --out "$1" --installed "$INSTALLED" \
		$(list "$2") ${refresh:+--refresh $refresh}
}

fetch "$B/pkgs" "$TOP/rootfs/packages-wifi.txt"
fetch "$B/pkgs/gui" "$TOP/rootfs/packages-gui.txt"
