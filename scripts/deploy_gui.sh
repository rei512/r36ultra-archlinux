#!/bin/bash
# SPDX-License-Identifier: MIT
# GUI 一式（gui-rootfs.tar）を SD カードの rootfs に展開する（2026-09-25）。root で実行。
# 全体の sync は使わない（WSL で 9p マウントに引っかかる）。sync -f で rootfs だけ同期する。
# 2026-09-30: 構成変更に合わせてパスを直した。
set -euo pipefail
TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STAGE=$TOP/build/gui_stage
TAR=$STAGE/gui-rootfs.tar
ROOTDEV=$(lsblk -rno NAME,LABEL | awk '$2=="rootfs"{print "/dev/"$1}')
[ "$(echo $ROOTDEV | wc -w)" = 1 ] || { echo "NG: ラベル rootfs が一意でない: '$ROOTDEV'"; exit 1; }
[ -s "$TAR" ] || { echo "NG: missing $TAR"; exit 1; }
echo "rootfs=$ROOTDEV  tar=$(stat -c %s "$TAR") B ($(date -r "$TAR" +%m-%d_%H:%M))"
mkdir -p /mnt/sdroot
mountpoint -q /mnt/sdroot && umount /mnt/sdroot
mount "$ROOTDEV" /mnt/sdroot
trap 'sync -f /mnt/sdroot 2>/dev/null; umount /mnt/sdroot 2>/dev/null || true' EXIT
echo "### 展開前のカード上の自前バイナリ"; ls -la --time-style=+%m-%d_%H:%M /mnt/sdroot/usr/local/bin/ | awk 'NR>3{print $5, $6, $7}'
echo "### 空き容量（1.5GB 以上あること）"; df -h /mnt/sdroot | tail -1
echo "### 展開"
tar -xpf "$TAR" -C /mnt/sdroot --no-overwrite-dir
sync -f /mnt/sdroot
echo "### 照合（build/gui_stage/rootfs と cmp）"
for f in usr/local/bin/r36u-status usr/local/bin/r36u-joyd usr/local/bin/start-sway usr/local/bin/wvkbd-mobintl usr/local/bin/osk-toggle etc/profile.d/r36u-sway.sh etc/systemd/system/r36u-joyd.service etc/sway/config; do
	cmp "$STAGE/rootfs/$f" "/mnt/sdroot/$f" && echo "OK $f"
done
echo "### 展開後"; ls -la --time-style=+%m-%d_%H:%M /mnt/sdroot/usr/local/bin/ | awk 'NR>3{print $5, $6, $7}'
sync -f /mnt/sdroot; umount /mnt/sdroot; trap - EXIT
echo "### 完了（GUI）"
