#!/bin/bash
# SPDX-License-Identifier: MIT
# 展開済みのカードを仕上げる（2026-09-25）。root で実行。全体の sync は使わない。
#  rootfs: syncfs → wpa 設定の残存確認 → umount
#  BOOT:   ro で mount → Image / DTB を現ビルドと cmp → 一覧 → umount
# 2026-09-30: 構成変更に合わせてパスを直した。
set -uo pipefail
TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
K=$TOP/kernel/linux-6.19/arch/arm64/boot
BOOTDEV=$(lsblk -rno NAME,LABEL | awk '$2=="BOOT"{print "/dev/"$1}')
ROOTDEV=$(lsblk -rno NAME,LABEL | awk '$2=="rootfs"{print "/dev/"$1}')
echo "BOOT=$BOOTDEV rootfs=$ROOTDEV"
echo "### rootfs"
if mountpoint -q /mnt/sdroot; then
	sync -f /mnt/sdroot && echo "syncfs ok"
	echo "wpa 接続先の残存（ssid= 行数、1 以上で OK）: $(grep -c 'ssid=' /mnt/sdroot/etc/wpa_supplicant/wpa_supplicant-wlan0.conf)"
	umount /mnt/sdroot && echo "umount /mnt/sdroot ok"
else
	echo "(rootfs はマウントされていない)"
fi
echo "### BOOT（ro で読み直して照合）"
mkdir -p /mnt/sdboot
mountpoint -q /mnt/sdboot && umount /mnt/sdboot
mount -o ro "$BOOTDEV" /mnt/sdboot
cmp "$K/Image" /mnt/sdboot/Image && echo "OK Image"
cmp "$K/dts/rockchip/rk3326-r36ultra-nodisp.dtb" /mnt/sdboot/rk3326-r36ultra-nodisp.dtb && echo "OK nodisp.dtb"
cmp "$K/dts/rockchip/rk3326-r36ultra.dtb" /mnt/sdboot/rk3326-r36ultra.dtb && echo "OK r36ultra.dtb"
echo "--- BOOT の一覧 ---"; ls -la --time-style=+%m-%d_%H:%M /mnt/sdboot | awk '{print $5, $6, $7}' | grep -E 'Image|dtb'
umount /mnt/sdboot && echo "umount /mnt/sdboot ok"
echo "### 完了。カードを抜いて実機へ"
