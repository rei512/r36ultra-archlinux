# ビルド

最終更新: 2026-10-01 / 対象コミット: 368e752

ソースから SD カードのイメージを作る。root は要らない。Ubuntu 24.04（WSL2）で、新しく clone した状態から最後まで通ることを確認した。

## 準備

```sh
sudo apt install build-essential gcc-aarch64-linux-gnu bc bison flex git python3 curl \
    kmod xz-utils pkgconf libwayland-bin openssl dosfstools e2fsprogs mtools fakeroot
git clone --recursive https://github.com/rei512/r36ultra-archlinux.git
cd r36ultra-archlinux
```

## 手順

```sh
scripts/fetch_packages.sh     # rootfs の tarball とパッケージを build/ に取得
scripts/build_kernel.sh       # v6.19 を取得し、パッチを当ててビルド
scripts/make_wifi_stage.sh    # WiFi ドライバをビルドし、WiFi 一式の tar を作る
scripts/make_sysroot.sh       # GUI のプログラムをビルドするための sysroot を作る
scripts/make_gui_stage.sh     # GUI 一式の tar を作る
scripts/make_image.sh         # SD カードのイメージを作る
```

## 成果物

| 成果物 | 場所 |
|---|---|
| イメージ | `build/r36ultra-archlinux-<日付>.img.xz`、`build/r36ultra-archlinux-<日付>.img.xz.sha256` |
| カーネル | `kernel/linux-6.19/arch/arm64/boot/Image` |
| DTB | `kernel/linux-6.19/arch/arm64/boot/dts/rockchip/rk3326-r36ultra-nodisp.dtb` |
| WiFi 一式 | `build/wifi_stage/wifi-rootfs.tar` |
| GUI 一式 | `build/gui_stage/gui-rootfs.tar` |

`<日付>` は作った日の `YYYY.MM.DD`。`RELEASE=2026.10.01 scripts/make_image.sh` のように指定もできる。Releases のタグは `v<日付>` にする。

パッケージは Arch Linux ARM のミラーにある、その時点の最新版になる。

## イメージの中身

| パーティション | 形式 | ラベル | 中身 |
|---|---|---|---|
| 1 | FAT32、256MB | `BOOT` | `Image`、`rk3326-r36ultra-nodisp.dtb`、`extlinux/extlinux.conf`、`boot.ini` |
| 2 | ext4 | `rootfs` | Arch Linux ARM の rootfs、WiFi 一式、GUI 一式 |

rootfs では、`/etc/fstab` で `BOOT` を `/boot/firmware` にマウントし、ホスト名を `R36Ultra`、root のパスワードを `root`、`/etc/machine-id` を `uninitialized` にしている。

## 使っているカードの更新

新しくイメージを書き込まずに、カーネルと tar だけを差し替える。カードを PC に挿して root で実行する。

| スクリプト | 差し替えるもの |
|---|---|
| `scripts/deploy_sd.sh` | Image、DTB、WiFi 一式、fstab |
| `scripts/deploy_image.sh` | Image だけ。カーネルのリリース名が変わるときは使わない |
| `scripts/deploy_gui.sh` | GUI 一式 |
| `scripts/finish_check.sh` | 書き込んだ内容の照合 |

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
├── rootfs/
│   ├── packages-wifi.txt       WiFi 一式のパッケージ
│   ├── packages-gui.txt        GUI 一式のパッケージ
│   └── overlay/                rootfs に追加する設定ファイル
├── boot/                       extlinux.conf、boot.ini
├── scripts/                    ビルドと書き込みのスクリプト
├── tools/diag_init/            起動診断用 init
├── docs/                       文書
└── build/                      取得物と生成物（git には入らない）
```
