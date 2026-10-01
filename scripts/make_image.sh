#!/bin/bash
# SPDX-License-Identifier: MIT
# Assemble the SD card image build/r36ultra-archlinux-YYYY.MM.DD.img.xz without root:
# the rootfs is unpacked under fakeroot, which keeps the owners and modes, and
# turned into an ext4 file system with mke2fs -d in the same fakeroot session;
# the FAT boot partition is filled with mtools. Needs the kernel
# (build_kernel.sh) and both stage tars (make_wifi_stage.sh, make_gui_stage.sh).
set -euo pipefail

TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
B=$TOP/build
KBOOT=$TOP/kernel/linux-6.19/arch/arm64/boot
ROOTFS_TAR=$B/ArchLinuxARM-aarch64-latest.tar.gz
WORK=$B/image
RELEASE=${RELEASE:-$(date +%Y.%m.%d)}	# the release tag is v$RELEASE
IMG=$B/r36ultra-archlinux-$RELEASE.img

SECTOR=512
BOOT_START=2048			# 1 MiB
BOOT_SECTORS=524288		# 256 MiB
ROOT_START=$((BOOT_START + BOOT_SECTORS))
IMG_MIB=7168			# 7 GiB, fits an 8 GB card
ROOT_SECTORS=$((IMG_MIB * 2048 - ROOT_START))

for f in "$KBOOT/Image" "$KBOOT/dts/rockchip/rk3326-r36ultra-nodisp.dtb" \
	"$B/wifi_stage/wifi-rootfs.tar" "$B/gui_stage/gui-rootfs.tar" "$ROOTFS_TAR"; do
	[ -s "$f" ] || { echo "missing $f" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK"

# 1) rootfs. Everything that has to be owned by root happens in one fakeroot
#    session, so mke2fs sees the owners tar set.
HASH=$(openssl passwd -6 root)
fakeroot -- bash -euo pipefail -c '
	R=$1/root
	mkdir "$R"
	tar -xpzf "$2" -C "$R" 2>/dev/null
	tar -xpf "$3" -C "$R" --no-overwrite-dir
	tar -xpf "$4" -C "$R" --no-overwrite-dir
	mkdir -p "$R/boot/firmware"
	printf "LABEL=BOOT      /boot/firmware  vfat    defaults        0 0\nLABEL=rootfs    /               ext4    defaults        0 1\n" > "$R/etc/fstab"
	echo R36Ultra > "$R/etc/hostname"
	# "uninitialized" makes the first boot a first boot for systemd
	# (ConditionFirstBoot); an empty file would not.
	echo uninitialized > "$R/etc/machine-id"
	sed -i "s|^root:[^:]*:|root:$6:|" "$R/etc/shadow"
	mke2fs -q -t ext4 -L rootfs -d "$R" "$1/rootfs.img" "$5"
' _ "$WORK" "$ROOTFS_TAR" "$B/wifi_stage/wifi-rootfs.tar" "$B/gui_stage/gui-rootfs.tar" \
	"$((ROOT_SECTORS / 2))k" "$HASH"
rm -rf "$WORK/root"

# 2) BOOT: kernel, device tree and boot configuration.
mkfs.fat -F 32 -n BOOT -C "$WORK/boot.img" $((BOOT_SECTORS / 2)) >/dev/null
export MTOOLS_SKIP_CHECK=1
mmd -i "$WORK/boot.img" ::/extlinux
mcopy -i "$WORK/boot.img" "$KBOOT/Image" "$KBOOT/dts/rockchip/rk3326-r36ultra-nodisp.dtb" \
	"$TOP/boot/boot.ini" ::/
mcopy -i "$WORK/boot.img" "$TOP/boot/extlinux.conf" ::/extlinux/

# 3) The card: MBR, BOOT (FAT32, bootable) and rootfs (Linux). The MBR is
#    written directly: sfdisk hangs in WSL before it even opens the file.
rm -f "$IMG" "$IMG.xz"
truncate -s "${IMG_MIB}M" "$IMG"
python3 - "$IMG" $BOOT_START $BOOT_SECTORS $ROOT_START $ROOT_SECTORS <<'EOF'
import struct, sys
img, boot_start, boot_n, root_start, root_n = sys.argv[1], *map(int, sys.argv[2:])
def entry(active, ptype, start, count):
    # CHS fields set to the "use LBA" value, as tools do for large disks
    return struct.pack("<B3sB3sII", 0x80 if active else 0, b"\xfe\xff\xff",
                       ptype, b"\xfe\xff\xff", start, count)
mbr = bytearray(512)
mbr[446:462] = entry(True, 0x0b, boot_start, boot_n)	# W95 FAT32
mbr[462:478] = entry(False, 0x83, root_start, root_n)	# Linux
mbr[510:512] = b"\x55\xaa"
with open(img, "r+b") as f:
    f.write(mbr)
EOF
dd if="$WORK/boot.img" of="$IMG" bs=$SECTOR seek=$BOOT_START conv=notrunc,sparse status=none
dd if="$WORK/rootfs.img" of="$IMG" bs=4M seek=$((ROOT_START * SECTOR)) oflag=seek_bytes \
	conv=notrunc,sparse status=none
rm -rf "$WORK"

xz -T0 -6 "$IMG"
# Bare file name, so that `sha256sum -c` works wherever the two files are put.
(cd "$B" && sha256sum "$(basename "$IMG").xz" > "$(basename "$IMG").xz.sha256")
echo "image: $IMG.xz ($(du -h "$IMG.xz" | cut -f1))"
cat "$IMG.xz.sha256"
