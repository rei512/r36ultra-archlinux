#!/bin/bash
# SPDX-License-Identifier: MIT
# R36Ultra の SD カードに、今のビルドの Image・DTB・wifi tar を反映する。root で実行。全体の sync は使わない。
#  BOOT:   fsck.fat -a（dirty フラグ解消）→ Image・DTB 2 つを cmp 付きで書く
#  rootfs: fstab を /boot/firmware に（§7.7）、/boot/firmware を作る、
#          wifi tar を展開（/etc/wpa_supplicant は除外）
#  最後に umount → BOOT を ro で読み直して再 cmp
# 元は 2026-09-29 の deploy_sd_v3.sh（local/rescued_scratch/）。構成変更に合わせてパスを直し、
# その回限りの処理（Image.prejoystick の削除、.bashrc の screenfetch のパス修正）を外した。
set -euo pipefail
TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
K=$TOP/kernel/linux-6.19/arch/arm64/boot
STAGE=$TOP/build/wifi_stage
TAR=$STAGE/wifi-rootfs.tar
KREL=$(cat "$TOP/kernel/linux-6.19/include/config/kernel.release")
BOOTDEV=$(lsblk -rno NAME,LABEL | awk '$2=="BOOT"{print "/dev/"$1}')
ROOTDEV=$(lsblk -rno NAME,LABEL | awk '$2=="rootfs"{print "/dev/"$1}')
[ "$(echo $BOOTDEV | wc -w)" = 1 ] && [ "$(echo $ROOTDEV | wc -w)" = 1 ] || { echo "NG: ラベル BOOT/rootfs が一意でない: '$BOOTDEV' '$ROOTDEV'"; exit 1; }
[ "${BOOTDEV%[0-9]}" = "${ROOTDEV%[0-9]}" ] || { echo "NG: BOOT と rootfs が別ディスク"; exit 1; }
echo "BOOT=$BOOTDEV rootfs=$ROOTDEV"
for f in "$K/Image" "$K/dts/rockchip/rk3326-r36ultra-nodisp.dtb" "$K/dts/rockchip/rk3326-r36ultra.dtb" "$TAR"; do [ -s "$f" ] || { echo "NG: missing $f"; exit 1; }; done
mkdir -p /mnt/sdboot /mnt/sdroot
mountpoint -q /mnt/sdboot && umount /mnt/sdboot
mountpoint -q /mnt/sdroot && umount /mnt/sdroot

echo; echo "### 1. BOOT の fsck（-a: 自動修復、dirty フラグを消す）"
fsck.fat -a "$BOOTDEV" || echo "(fsck.fat -a rc=$?)"
fsck.fat -n "$BOOTDEV" | tail -2

mount "$BOOTDEV" /mnt/sdboot
mount "$ROOTDEV" /mnt/sdroot
trap 'sync -f /mnt/sdboot 2>/dev/null; sync -f /mnt/sdroot 2>/dev/null; umount /mnt/sdboot 2>/dev/null || true; umount /mnt/sdroot 2>/dev/null || true' EXIT

echo; echo "### 2. BOOT: Image と DTB（.new に書いて cmp してから置き換え）"
for pair in "$K/Image:Image" "$K/dts/rockchip/rk3326-r36ultra-nodisp.dtb:rk3326-r36ultra-nodisp.dtb" "$K/dts/rockchip/rk3326-r36ultra.dtb:rk3326-r36ultra.dtb"; do
	src=${pair%%:*}; dst=/mnt/sdboot/${pair##*:}
	cp "$src" "$dst.new"; sync -f /mnt/sdboot
	cmp "$src" "$dst.new" || { echo "NG: cmp $dst.new"; exit 1; }
	mv "$dst.new" "$dst"; sync -f /mnt/sdboot
	echo "OK $(basename "$dst") ($(stat -c %s "$dst") B)"
done

echo; echo "### 3. rootfs: fstab → /boot/firmware"
echo "-- 変更前の fstab:"; cat /mnt/sdroot/etc/fstab
mkdir -p /mnt/sdroot/boot/firmware
printf 'LABEL=BOOT      /boot/firmware  vfat    defaults        0 0\nLABEL=rootfs    /               ext4    defaults        0 1\n' > /mnt/sdroot/etc/fstab
echo "-- 変更後の fstab:"; cat /mnt/sdroot/etc/fstab

echo; echo "### 4. rootfs: wifi tar（$KREL のモジュール）を展開（/etc/wpa_supplicant は除外）"
tar -xpf "$TAR" -C /mnt/sdroot --no-overwrite-dir --exclude='./etc/wpa_supplicant/*'
cmp "$STAGE/rootfs/usr/lib/modules/$KREL/updates/rk915.ko" "/mnt/sdroot/usr/lib/modules/$KREL/updates/rk915.ko" && echo "OK rk915.ko"
cmp "$STAGE/rootfs/usr/lib/modules/$KREL/kernel/net/wireless/cfg80211.ko" "/mnt/sdroot/usr/lib/modules/$KREL/kernel/net/wireless/cfg80211.ko" && echo "OK cfg80211.ko"
echo "wpa 接続先の残存（ssid= 行数、1 以上で OK）: $(grep -c 'ssid=' /mnt/sdroot/etc/wpa_supplicant/wpa_supplicant-wlan0.conf)"
grep -qx 'WIRELESS_REGDOM="JP"' /mnt/sdroot/etc/conf.d/wireless-regdom && echo "OK wireless-regdom JP"

echo; echo "### 5. umount → BOOT を読み直して再照合"
sync -f /mnt/sdboot; sync -f /mnt/sdroot; umount /mnt/sdboot; umount /mnt/sdroot; trap - EXIT
mount -o ro "$BOOTDEV" /mnt/sdboot
cmp "$K/Image" /mnt/sdboot/Image && echo "OK Image（再読込）"
cmp "$K/dts/rockchip/rk3326-r36ultra-nodisp.dtb" /mnt/sdboot/rk3326-r36ultra-nodisp.dtb && echo "OK nodisp.dtb（再読込）"
cmp "$K/dts/rockchip/rk3326-r36ultra.dtb" /mnt/sdboot/rk3326-r36ultra.dtb && echo "OK r36ultra.dtb（再読込）"
ls -la --time-style=+%m-%d_%H:%M /mnt/sdboot | awk '{print $5, $6, $7}' | grep -E 'Image|dtb'
umount /mnt/sdboot
echo; echo "### 完了。カードを抜いて実機へ（USB 給電のまま電源 ON）"
