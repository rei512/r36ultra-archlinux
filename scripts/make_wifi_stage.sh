#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the rootfs overlay for RK915 WiFi. Everything the rootfs needs for WiFi
# goes in here, so a new card only has to extract wifi-rootfs.tar (§7.7):
#   - the modules WiFi needs (and their dependencies) and the firmware
#   - the userspace tools (wpa_supplicant, iw, wireless-regdb) as plain files
#     taken from the Arch Linux ARM packages in build/pkgs/; pacman does not know
#     about them (see §10.13); the regulatory domain set to JP
#   - the enabled services and an empty wpa_supplicant config for wlan0
#   - root login over ssh with the password
#   - a per-device WiFi MAC address and a first-boot password notice
# Everything else built by "make modules" is deliberately left out, so udev
# cannot autoload unrelated drivers (e.g. rk817_charger with ODROID-Go
# battery values).
set -euo pipefail

TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KSRC=$TOP/kernel/linux-6.19
DRV=$TOP/modules/rk915
PKGS=$TOP/build/pkgs
OUT=$TOP/build/wifi_stage
OVERLAY=$TOP/rootfs/overlay/wifi	# config files; git keeps only 644/755, so modes are set below
MAKEARGS="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"

KREL=$(cat "$KSRC/include/config/kernel.release")
FULL=$(mktemp -d)
trap 'rm -rf "$FULL"' EXIT

# 1) Build rk915 with source paths relative to the repository: kbuild shortens
#    only the paths of an external module's own sources, and the kernel headers'
#    __FILE__ would otherwise put the absolute build path into rk915.ko.
make -C "$KSRC" $MAKEARGS M="$DRV" KCFLAGS="-ffile-prefix-map=$TOP/=" modules >/dev/null

#    Install every module into a throw-away tree (stripped).
make -C "$KSRC" $MAKEARGS INSTALL_MOD_PATH="$FULL" INSTALL_MOD_STRIP=1 modules_install >/dev/null
make -C "$KSRC" $MAKEARGS M="$DRV" INSTALL_MOD_PATH="$FULL" INSTALL_MOD_STRIP=1 modules_install >/dev/null

SRC=$FULL/lib/modules/$KREL
[ -d "$SRC" ] || SRC=$FULL/usr/lib/modules/$KREL
DEPMOD_TOOL=/sbin/depmod

# 2) Resolve the dependency closure of the modules WiFi needs.
declare -A want
add() {
	local m=$1 f dep
	[ -n "${want[$m]:-}" ] && return
	f=$(find "$SRC" -name "$m.ko*" | head -1)
	[ -n "$f" ] || { echo "missing module: $m" >&2; exit 1; }
	want[$m]=${f#$SRC/}
	for dep in $(modinfo -F depends "$f" | tr ',' ' '); do
		add "$dep"
	done
}
add rk915
add cfg80211
add mac80211

# 3) Assemble the overlay (Arch: /lib -> usr/lib).
rm -rf "$OUT"
DST=$OUT/rootfs/usr/lib/modules/$KREL
mkdir -p "$DST"
for m in "${!want[@]}"; do
	mkdir -p "$DST/$(dirname "${want[$m]}")"
	cp "$SRC/${want[$m]}" "$DST/${want[$m]}"
done
cp "$SRC"/modules.builtin "$SRC"/modules.builtin.modinfo "$SRC"/modules.order "$DST"/
"$DEPMOD_TOOL" -b "$OUT/rootfs/usr" "$KREL"

mkdir -p "$OUT/rootfs/usr/lib/firmware/rockchip"
install -m644 "$DRV/firmware/rockchip/rk915_fw.bin" "$DRV/firmware/rockchip/rk915_patch.bin" \
   "$OUT/rootfs/usr/lib/firmware/rockchip/"

# 4) Userspace, as plain files from the Arch packages. The package metadata
#    (.PKGINFO etc.) is left out. wpa_supplicant links libpcsclite.so.1, which
#    depends on nothing but libc, so only that library is taken from pcsclite;
#    the rest of pcsclite (and its polkit/duktape dependencies) is for pcscd,
#    which is not used. --force-local: the wpa_supplicant file name contains
#    ':' (the epoch), which tar would otherwise read as a host name.
PKG_EXCLUDE=(--exclude=.PKGINFO --exclude=.MTREE --exclude=.BUILDINFO --exclude=.INSTALL --exclude=.CHANGELOG)
pkg_file() {
	local f
	f=$(ls "$PKGS"/$1-[0-9]*.pkg.tar.xz)
	[ -f "$f" ] || { echo "missing package: $1" >&2; exit 1; }
	echo "$f"
}
used_pkgs=()
for p in wpa_supplicant iw wireless-regdb; do
	f=$(pkg_file "$p")
	tar --force-local -xpJf "$f" -C "$OUT/rootfs" "${PKG_EXCLUDE[@]}"
	used_pkgs+=("$(basename "$f")")
done
f=$(pkg_file pcsclite)
tar --force-local -xpJf "$f" -C "$OUT/rootfs" --wildcards 'usr/lib/libpcsclite.so.1*'
used_pkgs+=("$(basename "$f") (usr/lib/libpcsclite.so.1* only)")

# 4b) Regulatory domain. wireless-regdb ships /etc/conf.d/wireless-regdom with
#     every country commented out; its udev rule runs set-wireless-regdom when
#     cfg80211 loads, which exits 1 while nothing is set. Enable JP. This only
#     takes effect once the kernel accepts regulatory.db, which needs
#     CONFIG_CRYPTO_SHA256=y for the signature check (§10.13).
REGDOM=$OUT/rootfs/etc/conf.d/wireless-regdom
sed -i 's/^#WIRELESS_REGDOM="JP"$/WIRELESS_REGDOM="JP"/' "$REGDOM"
grep -qx 'WIRELESS_REGDOM="JP"' "$REGDOM" || { echo "wireless-regdom: JP not enabled" >&2; exit 1; }

# 5) Services enabled for wlan0 (both units: WantedBy=multi-user.target), and
#    the config the wpa_supplicant@wlan0 unit expects. No network block: the
#    SSID and passphrase are added on the device (wpa_passphrase >> this file),
#    and update_config=1 lets wpa_cli save networks into it.
WANTS=$OUT/rootfs/etc/systemd/system/multi-user.target.wants
mkdir -p "$WANTS"
ln -s /usr/lib/systemd/system/wpa_supplicant@.service "$WANTS/wpa_supplicant@wlan0.service"
ln -s /usr/lib/systemd/system/dhcpcd@.service "$WANTS/dhcpcd@wlan0.service"
mkdir -p "$OUT/rootfs/etc/wpa_supplicant"
install -m600 "$OVERLAY/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" "$OUT/rootfs/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

# 5b) ssh as root with the password. The rootfs tarball already enables
#     sshd.service; its sshd_config reads sshd_config.d/*.conf first and keeps
#     OpenSSH's PermitRootLogin prohibit-password. sshd takes the first value it
#     reads, so 10-* comes before the tarball's 20-* and 99-* drop-ins.
install -d "$OUT/rootfs/etc/ssh/sshd_config.d"
install -m644 "$OVERLAY/etc/ssh/sshd_config.d/10-r36ultra.conf" "$OUT/rootfs/etc/ssh/sshd_config.d/10-r36ultra.conf"

# 5c) A MAC address per device that survives reboots: r36u-wlan-mac derives it
#     from /etc/machine-id and hands it to rk915 as a module option before udev
#     loads the driver. And on the first boot only, a notice of the default
#     root password on every console. Both enabled through the symlinks
#     `systemctl enable` would create.
install -d "$OUT/rootfs/usr/local/bin" "$OUT/rootfs/etc/systemd/system/sysinit.target.wants"
install -m755 "$OVERLAY/usr/local/bin/r36u-wlan-mac" "$OUT/rootfs/usr/local/bin/r36u-wlan-mac"
for unit in r36u-wlan-mac.service r36u-default-password.service; do
	install -m644 "$OVERLAY/etc/systemd/system/$unit" "$OUT/rootfs/etc/systemd/system/$unit"
done
ln -s /etc/systemd/system/r36u-wlan-mac.service "$OUT/rootfs/etc/systemd/system/sysinit.target.wants/r36u-wlan-mac.service"
ln -s /etc/systemd/system/r36u-default-password.service "$WANTS/r36u-default-password.service"

# 6) Pack with root ownership; no directory entries so extraction never
#    rewrites the mode of existing directories on the card.
(cd "$OUT/rootfs" && find . \( -type f -o -type l \) | sort | \
	tar --owner=0 --group=0 --no-recursion -cf "$OUT/wifi-rootfs.tar" -T -)

echo "kernel release: $KREL"
echo "modules:"; printf '  %s\n' "${want[@]}" | sort
echo "packages:"; printf '  %s\n' "${used_pkgs[@]}"
echo "archive: $OUT/wifi-rootfs.tar ($(tar -tf "$OUT/wifi-rootfs.tar" | wc -l) entries)"
tar -tvf "$OUT/wifi-rootfs.tar" | grep -v -E "usr/share/(man|doc|licenses)/"
