#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the kernel: fetch Linux v6.19 into kernel/linux-6.19 if it is not there,
# apply kernel/patches, install kernel/config as .config, and build the Image,
# the modules and the two R36Ultra device trees.
set -euo pipefail

TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KSRC=$TOP/kernel/linux-6.19
MAKEARGS=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
DTBS=(rockchip/rk3326-r36ultra.dtb rockchip/rk3326-r36ultra-nodisp.dtb)

if [ ! -d "$KSRC" ]; then
	git clone --depth 1 -b v6.19 \
		https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$KSRC"
	git -C "$KSRC" -c user.name=build -c user.email=build@localhost \
		am "$TOP"/kernel/patches/*.patch
fi

cp "$TOP/kernel/config" "$KSRC/.config"
make -C "$KSRC" "${MAKEARGS[@]}" olddefconfig
make -C "$KSRC" "${MAKEARGS[@]}" -j"$(nproc)" Image modules "${DTBS[@]}"

echo "kernel release: $(cat "$KSRC/include/config/kernel.release")"
