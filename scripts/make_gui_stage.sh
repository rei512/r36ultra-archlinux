#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the rootfs overlay for the GUI (sway on simpledrm). Everything the
# rootfs needs for it goes in here, so a new card only has to extract
# gui-rootfs.tar the same way as wifi-rootfs.tar (§7.7):
#   - the Arch Linux ARM packages in build/pkgs/gui as plain files; fetch_pkgs.py
#     resolved the dependency closure against core/extra/alarm. pacman does not
#     know about them (use --overwrite '*' if they are ever installed properly)
#   - glibc: the rootfs tarball ships 2.42, and packages built now need symbols
#     from 2.43 (foot: log10f@GLIBC_2.43), so the newer glibc is part of the
#     overlay. Its /etc files are left out so the card keeps its own config.
#   - a minimal sway config for the 720x720 panel and a start-sway helper
# The archive is extracted on the PC with the card mounted (§7.7), never on the
# running device: it replaces libraries the running system would be using.
set -euo pipefail

TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PKGS=$TOP/build/pkgs/gui
OUT=$TOP/build/gui_stage
OVERLAY=$TOP/rootfs/overlay/gui	# config files; git keeps only 644/755, so modes are set below
SYSROOT=$TOP/build/sysroot
WVKBD=$TOP/userspace/wvkbd
ROOTFS_TAR=$TOP/build/ArchLinuxARM-aarch64-latest.tar.gz
ROOTFS_LIBS=$OUT/rootfs-libs.txt	# cached: shared libraries the card already has

# Package metadata is not part of the rootfs. --force-local: several file names
# contain ':' (the epoch), which tar would otherwise read as a host name.
PKG_EXCLUDE=(--exclude=.PKGINFO --exclude=.MTREE --exclude=.BUILDINFO --exclude=.INSTALL --exclude=.CHANGELOG)

rm -rf "$OUT/rootfs"
mkdir -p "$OUT/rootfs"

# 1) Unpack every package into the overlay tree.
n=0
for f in "$PKGS"/*.pkg.tar.xz; do
	extra=()
	case $(basename "$f") in
	glibc-*) extra=(--exclude=etc) ;;
	esac
	tar --force-local -xpJf "$f" -C "$OUT/rootfs" "${PKG_EXCLUDE[@]}" "${extra[@]}"
	n=$((n + 1))
done

# 1b) Extra programs in those packages that link libraries nothing else here
#     needs (python comes in with libgpiod's bindings). None of them is used by
#     sway or foot, and pulling rrdtool, glut, gd, libheif and tcl/tk in for them
#     would roughly double the overlay. Unquoted on purpose: the last one globs.
for drop in \
	usr/bin/sensord \
	usr/bin/tiffgt \
	usr/bin/memusagestat \
	usr/lib/glycin-loaders/2+/glycin-heif \
	'usr/lib/python3*/lib-dynload/_tkinter.*.so'
do
	rm -f $OUT/rootfs/$drop
done

# 2) sway's configuration. One window fills the panel, and layer-shell surfaces
#    (the on-screen keyboard, the status strip) keep their own space because the
#    window is tiled rather than fullscreen.
install -d "$OUT/rootfs/etc/sway"
install -m644 "$OVERLAY/etc/sway/config" "$OUT/rootfs/etc/sway/config"

# 2b) foot's configuration, replacing the example the package ships. The default
#     (monospace:size=8, i.e. DejaVu Sans Mono) is thin and widely spaced on this
#     panel, so a bitmap font is the default here and two outline fonts are left
#     ready to switch to.
install -d "$OUT/rootfs/etc/xdg/foot"
install -m644 "$OVERLAY/etc/xdg/foot/foot.ini" "$OUT/rootfs/etc/xdg/foot/foot.ini"

# 2c) Straight into the GUI on the panel: tty1 logs in as root by itself and its
#     login shell starts sway. The serial console keeps its login prompt, so a
#     broken GUI still leaves a way in. Not `exec`: when sway exits the shell is
#     still there, instead of the login-restart-login loop an exec would give.
install -d "$OUT/rootfs/etc/systemd/system/getty@tty1.service.d"
install -m644 "$OVERLAY/etc/systemd/system/getty@tty1.service.d/autologin.conf" \
	"$OUT/rootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf"

install -d "$OUT/rootfs/etc/profile.d"
install -m644 "$OVERLAY/etc/profile.d/r36u-sway.sh" "$OUT/rootfs/etc/profile.d/r36u-sway.sh"

#     systemd's "[  OK  ]" status goes to /dev/console, which is a single device
#     - the last console= on the kernel command line, the panel since
#     extlinux.conf (2026-09-30: the v27 variant, renamed). Userspace logs are forwarded to the kernel log buffer
#     instead of to one tty, because the kernel prints that buffer to *every*
#     console: panel and serial both get the same lines, in one timeline (they
#     also end up in dmesg). journald turns off the kernel's rate limit for
#     userspace writes by itself; the buffer is enlarged on the command line
#     (log_buf_len=8M) as journald.conf(5) recommends -- NOT yet on the card:
#     the variant that added it (v28) was never deployed, so the buffer is the
#     default size (CONFIG_LOG_BUF_SHIFT) and old lines are overwritten sooner.
#     MaxLevelKMsg defaults to "notice", which would drop the "Started ..."
#     lines, so it is set to "info". Set ForwardToKMsg=no to turn all this off.
install -d "$OUT/rootfs/etc/systemd/journald.conf.d"
install -m644 "$OVERLAY/etc/systemd/journald.conf.d/console.conf" "$OUT/rootfs/etc/systemd/journald.conf.d/console.conf"

# 3) Launcher for the serial console. WLR_RENDERER=pixman: the panel is U-Boot's
#    framebuffer handed to simpledrm, which has no GPU driver, so wlroots renders
#    on the CPU instead of going through mesa. seatd-launch provides the seat
#    that wlroots needs to open the DRM device and the input devices.
install -d "$OUT/rootfs/usr/local/bin"
install -m755 "$OVERLAY/usr/local/bin/start-sway" "$OUT/rootfs/usr/local/bin/start-sway"

# 3b) The analog sticks. All four axes are multiplexed onto one SARADC channel,
#     which mainline's adc-joystick cannot describe, so r36u-joyd switches the
#     mux and publishes a gamepad and a pointer through uinput (see r36u_joyd.c
#     for the measured mapping). Built here, so the overlay always carries a
#     binary that matches the source in this directory.
aarch64-linux-gnu-gcc -O2 -Wall -Wextra -o "$OUT/rootfs/usr/local/bin/r36u-joyd" \
	"$TOP/userspace/r36u-joyd/r36u_joyd.c"

#     Status: one line for sway's bar, or a full-screen view with -f, where the
#     LEDs can be switched (see r36u_statusd.c).
aarch64-linux-gnu-gcc -O2 -Wall -Wextra -o "$OUT/rootfs/usr/local/bin/r36u-status" \
	"$TOP/userspace/r36u-status/r36u_statusd.c"

#     Enabled through the same symlink `systemctl enable` would create, so a new
#     card gets it from the archive instead of a command typed on the device.
install -d "$OUT/rootfs/etc/systemd/system" \
	"$OUT/rootfs/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/r36u-joyd.service \
	"$OUT/rootfs/etc/systemd/system/multi-user.target.wants/r36u-joyd.service"
install -m644 "$OVERLAY/etc/systemd/system/r36u-joyd.service" "$OUT/rootfs/etc/systemd/system/r36u-joyd.service"

# 3c) On-screen keyboard. wvkbd is not in the Arch Linux ARM repositories, so it
#     is built here from userspace/wvkbd/ against build/sysroot/ (make_sysroot.sh),
#     which is the card's own libraries with build/pkgs/gui on top. Only the
#     binary: its man page needs scdoc, which is not installed here. The prefix
#     map keeps the build path out of its debug info; it goes in CC because
#     CFLAGS on the command line would replace the Makefile's pkg-config flags.
[ -d "$SYSROOT/usr/lib/pkgconfig" ] || { echo "run scripts/make_sysroot.sh first" >&2; exit 1; }
make -C "$WVKBD" clean >/dev/null
PKG_CONFIG_SYSROOT_DIR=$SYSROOT \
PKG_CONFIG_LIBDIR=$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig \
	make -C "$WVKBD" CC="aarch64-linux-gnu-gcc --sysroot=$SYSROOT -ffile-prefix-map=$TOP/=" \
	wvkbd-mobintl >/dev/null
install -m755 "$WVKBD/wvkbd-mobintl" "$OUT/rootfs/usr/local/bin/wvkbd-mobintl"

#     wvkbd hides on SIGUSR1, shows on SIGUSR2 and toggles on SIGRTMIN.
install -m755 "$OVERLAY/usr/local/bin/osk-toggle" "$OUT/rootfs/usr/local/bin/osk-toggle"

# 4) Check that every shared library the overlay's binaries ask for is either in
#    the overlay or already on the card. A missing one only shows up as "cannot
#    open shared object file" on the device, long after the card is written.
if [ ! -s "$ROOTFS_LIBS" ]; then
	tar -tzf "$ROOTFS_TAR" | grep -oE '[^/]+\.so(\.[0-9]+)*$' | sort -u > "$ROOTFS_LIBS"
fi
have=$(mktemp)
trap 'rm -f "$have"' EXIT
{
	cat "$ROOTFS_LIBS"
	find "$OUT/rootfs" \( -type f -o -type l \) -name '*.so*' -printf '%f\n'
} | sort -u > "$have"

missing=0
while read -r elf; do
	for lib in $(readelf -d "$elf" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do
		grep -qxF "$lib" "$have" || { echo "missing library: $lib (needed by ${elf#$OUT/rootfs})"; missing=$((missing + 1)); }
	done
done < <(find "$OUT/rootfs/usr/bin" "$OUT/rootfs/usr/lib" "$OUT/rootfs/usr/local/bin" -type f 2>/dev/null)
[ "$missing" -eq 0 ] || { echo "$missing unresolved libraries" >&2; exit 1; }

# 5) Pack with root ownership; no directory entries so extraction never rewrites
#    the mode of existing directories on the card.
(cd "$OUT/rootfs" && find . \( -type f -o -type l \) | sort | \
	tar --owner=0 --group=0 --no-recursion -cf "$OUT/gui-rootfs.tar" -T -)

echo "packages: $n (from $PKGS)"
echo "libraries: all resolved (overlay + card)"
echo "archive: $OUT/gui-rootfs.tar ($(tar -tf "$OUT/gui-rootfs.tar" | wc -l) entries, $(du -h "$OUT/gui-rootfs.tar" | cut -f1))"
