# インストール

最終更新: 2026-10-01 / 対象コミット: 368e752

## 前提

- 純正ファームウェアの U-Boot が eMMC に入った R36Ultra。このイメージは U-Boot を含まず、eMMC の U-Boot が SD カードから起動する
- 8GB 以上の SD カード

このイメージは eMMC に書き込まない。カーネルのデバイスツリーで eMMC を無効にしているので、Linux からは eMMC が見えない。

## SD カードへの書き込み

Releases から `r36ultra-archlinux-<日付>.img.xz` と `.sha256` を取得し、照合する。

```sh
sha256sum -c r36ultra-archlinux-*.img.xz.sha256
```

`/dev/sdX` は SD カードのデバイスに置き換える。

```sh
xz -dc r36ultra-archlinux-*.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Windows では balenaEtcher や Rufus で書き込める。

## 初回起動

SD カードを差して電源を入れる。ログインは `root` / `root`。

初回起動時に、機体ごとの machine-id と、それから作る WiFi の MAC アドレスが決まる。以後は起動しても変わらない。

## WiFi

```sh
wpa_passphrase "SSID" "パスフレーズ" >> /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
systemctl restart wpa_supplicant@wlan0
```

IP アドレスは `ip addr show wlan0` で分かる。

## ssh

WiFi につながると、`root` / `root` で ssh に入れる。パスワードは `passwd` で変えられる。

```sh
ssh root@<IP アドレス>
```

## シリアルコンソール

UART5、1.5 Mbps。

## 更新

`pacman -Syu` は試していない。WiFi と GUI のパッケージの一部と glibc は、pacman を通さずにファイルとして入れているので、pacman の管理外になっている。

カーネルは pacman では更新されない。起動に使うカーネルは `/boot/firmware` にあり、pacman の `linux-aarch64` が書き込むのは `/boot`。
