# R36Ultra 用 Arch Linux ARM

R36Ultra（Rockchip RK3326）向けの非公式 Arch Linux ARM。カーネルは mainline Linux 6.19。

## ログイン

- ユーザー: `root`
- パスワード: `root`

## 動作状況

動作するもの:

- 画面表示
- ボタン、アナログスティック
- WiFi、ssh
- sway、画面キーボード
- 熱管理、RTC、電池残量
- USB マウス・キーボード（OTG 端子に接続）

未対応・未確認:

- 音声
- 音量ボタン
- GPU 描画
- WiFi の大容量通信

## 必要なもの

- 純正の U-Boot が eMMC に入った R36Ultra
- 8GB 以上の SD カード

シリアルコンソールは UART5、1.5 Mbps。

## WiFi の設定

```sh
wpa_passphrase "SSID" "パスフレーズ" >> /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
systemctl restart wpa_supplicant@wlan0
```

## ビルド

Ubuntu 24.04 で確認。

```sh
sudo apt install build-essential gcc-aarch64-linux-gnu bc bison flex git python3 \
    kmod xz-utils pkgconf libwayland-bin openssl dosfstools e2fsprogs fdisk
```

```sh
git clone --recursive https://github.com/rei512/r36ultra-archlinux.git
cd r36ultra-archlinux
```

### カーネル

```sh
git clone --depth 1 -b v6.19 \
    https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git kernel/linux-6.19
cd kernel/linux-6.19
git am ../patches/*.patch
cp ../config .config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image modules
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    rockchip/rk3326-r36ultra.dtb rockchip/rk3326-r36ultra-nodisp.dtb
cd ../..
```

### WiFi ドライバ

```sh
make -C kernel/linux-6.19 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    M=$PWD/modules/rk915 modules
```

### rootfs

`build/` に `ArchLinuxARM-aarch64-latest.tar.gz` を、`build/pkgs/` と `build/pkgs/gui/` にパッケージを置いて実行する。

```sh
scripts/make_wifi_stage.sh
scripts/make_sysroot.sh
scripts/make_gui_stage.sh
```

### ビルド成果物

| 成果物 | 場所 |
|---|---|
| カーネル | `kernel/linux-6.19/arch/arm64/boot/Image` |
| DTB | `kernel/linux-6.19/arch/arm64/boot/dts/rockchip/rk3326-r36ultra-nodisp.dtb` |
| WiFi 一式 | `build/wifi_stage/wifi-rootfs.tar` |
| GUI 一式 | `build/gui_stage/gui-rootfs.tar` |

### SD カード

MBR で 2 つのパーティションを作る。

| パーティション | 形式 | ラベル |
|---|---|---|
| 1 | FAT32、256MB | `BOOT` |
| 2 | ext4、残り全部 | `rootfs` |

`BOOT` に置くファイル:

| カード上 | 元のファイル |
|---|---|
| `/Image` | `kernel/linux-6.19/arch/arm64/boot/Image` |
| `/rk3326-r36ultra-nodisp.dtb` | `kernel/linux-6.19/arch/arm64/boot/dts/rockchip/rk3326-r36ultra-nodisp.dtb` |
| `/extlinux/extlinux.conf` | `boot/extlinux.conf` |
| `/boot.ini` | `boot/boot.ini` |

`rootfs` に展開するもの:

```sh
tar -xpzf build/ArchLinuxARM-aarch64-latest.tar.gz -C <rootfs>
tar -xpf build/wifi_stage/wifi-rootfs.tar -C <rootfs> --no-overwrite-dir
tar -xpf build/gui_stage/gui-rootfs.tar -C <rootfs> --no-overwrite-dir
```

`rootfs` で書き換えるファイル:

| ファイル | 内容 |
|---|---|
| `/etc/fstab` | `LABEL=BOOT /boot/firmware vfat defaults 0 0` と `LABEL=rootfs / ext4 defaults 0 1` |
| `/etc/machine-id` | `uninitialized` |
| `/etc/hostname` | `R36Ultra` |
| `/etc/shadow` | root のパスワードを `root` にする（`openssl passwd -6 root` のハッシュ） |

`/boot/firmware` のディレクトリも作っておく。

詳細は [docs/R36Ultra-MainlineLinux.md](docs/R36Ultra-MainlineLinux.md)。

## ディレクトリ構成

```
.
├── kernel/
│   ├── config                  カーネルの設定
│   └── patches/                v6.19 へのパッチ
├── modules/rk915/              WiFi ドライバ
├── userspace/
│   ├── r36u-joyd/              アナログスティック・マウスカーソル
│   ├── r36u-status/            状態表示
│   └── wvkbd/                  画面キーボード
├── rootfs/overlay/
│   ├── wifi/                   WiFi・ssh の設定
│   └── gui/                    sway・foot・自動ログインの設定
├── boot/
│   ├── extlinux.conf
│   └── boot.ini
├── scripts/
│   ├── fetch_pkgs.py           パッケージの取得
│   ├── make_wifi_stage.sh      wifi-rootfs.tar の作成
│   ├── make_sysroot.sh         GUI ビルド用 sysroot の作成
│   ├── make_gui_stage.sh       gui-rootfs.tar の作成
│   ├── deploy_sd.sh            SD カードへの書き込み
│   ├── deploy_image.sh         Image のみ書き込み
│   ├── deploy_gui.sh           gui-rootfs.tar の展開
│   └── finish_check.sh         書き込み後の照合
├── tools/diag_init/            起動診断用 init
└── docs/                       作業記録
```

## ライセンス

- このリポジトリのスクリプト・プログラム・設定ファイル: MIT（`LICENSE`）
- カーネルのパッチ、rk915: GPL-2.0
- DTS: GPL-2.0+ または MIT
- wvkbd: GPL-3.0

## 謝辞

- [Arch Linux ARM](https://archlinuxarm.org/)
- [sunshineinabox/rk915](https://github.com/sunshineinabox/rk915)、ROCKNIX
- [wvkbd](https://github.com/jjsullivan5196/wvkbd)
