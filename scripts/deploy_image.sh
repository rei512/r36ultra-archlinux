#!/bin/bash
# SPDX-License-Identifier: MIT
# R36Ultra の SD カードに 現ビルドの Image だけを反映する。root で実行。全体の sync は使わない。
# 元は 2026-09-29 の deploy_sd_v4.sh（local/rescued_scratch/）。構成変更に合わせてパスを直した。
# カーネルのリリース名が変わったビルドでは使わない（モジュールと合わなくなる。deploy_sd.sh を使う）。
set -euo pipefail
TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
K=$TOP/kernel/linux-6.19/arch/arm64/boot
BOOTDEV=$(lsblk -rno NAME,LABEL | awk '$2=="BOOT"{print "/dev/"$1}')
[ "$(echo $BOOTDEV | wc -w)" = 1 ] || { echo "NG: ラベル BOOT が一意でない: '$BOOTDEV'"; exit 1; }
echo "BOOT=$BOOTDEV  Image=$(sha256sum "$K/Image" | cut -c1-16)…"
mkdir -p /mnt/sdboot; mountpoint -q /mnt/sdboot && umount /mnt/sdboot
mount "$BOOTDEV" /mnt/sdboot; trap 'sync -f /mnt/sdboot 2>/dev/null; umount /mnt/sdboot 2>/dev/null || true' EXIT
rm -f /mnt/sdboot/Image.new
cp "$K/Image" /mnt/sdboot/Image.new; sync -f /mnt/sdboot; cmp "$K/Image" /mnt/sdboot/Image.new
mv /mnt/sdboot/Image.new /mnt/sdboot/Image; sync -f /mnt/sdboot; echo "OK Image ($(stat -c %s /mnt/sdboot/Image) B)"
umount /mnt/sdboot; trap - EXIT
mount -o ro "$BOOTDEV" /mnt/sdboot; cmp "$K/Image" /mnt/sdboot/Image && echo "OK Image（再読込）"; umount /mnt/sdboot
echo "### 完了。カードを実機へ"
