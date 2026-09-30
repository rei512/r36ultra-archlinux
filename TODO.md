# R36Ultra mainline Linux — 残課題と引き継ぎ（2026-09-30）

作業の経緯と判断は `R36Ultra-MainlineLinux.md`（特に §10.11〜§10.15）、Claude 向けの要約は `CLAUDE.md`。
このファイルは「次に何をするか」だけをまとめたもの。GitHub 公開の残作業は §5。

## 0. いまの状態

- カーネル #20（mainline 6.19。カードの Image は分割前の未コミット状態からのビルドで、リリース名 `6.19.0-gfb5ef0332d8f-dirty`）。2026-09-30 に `kernel/linux-6.19/` の変更を `r36ultra`（3 コミット）と `experiment/dsi-reinit` に分けた。`r36ultra` の Image は実機未確認。表示は U-Boot の画面を simpledrm で引き継ぐ方式（DTB は `rk3326-r36ultra-nodisp.dtb`）。
- 実機で確認済み：起動・表示・入力（17 ボタン + 多重化スティック）・WiFi（国コード JP）・sway 自動起動・ssh（root/root）・熱管理（thermal zone 2 つ）・RTC・電池ゲージ（満充電で較正済み）・GPU ドライバ panfrost（`renderD128`）・`poweroff` で電源が切れる・Landlock（pacman 7.1 のサンドボックス）。
- カード：fstab は BOOT を `/boot/firmware` に載せる（`/boot` は rootfs 側の通常ディレクトリ。`pacman -Syu` しても自作 Image は上書きされない）。FAT の dirty フラグは解消済み。BOOT の中身は `Image`・DTB 2 つ・`extlinux/`・`boot.ini`・`screenfetch.sh`。
- 実機の IP は DHCP で変わる。Windows 側で `arp.exe -a` から実機の MAC を探す（WSL2 からは LAN の ARP が見えない）。

## 1. 残課題（優先順）

### A. sshd を wifi の stage tar に入れる（2026-09-30 済、実機未確認）
- 作業者の指示（root/root のまま ssh 可能にする）で実施。`rootfs/overlay/wifi/etc/ssh/sshd_config.d/10-r36ultra.conf`（`PermitRootLogin yes`）を `make_wifi_stage.sh` が入れる。tar の差分はこの 1 項目だけであることを確認済み。
- 旧パッチ（`local/rescued_scratch/make_wifi_stage_sshd.patch`）の「tarball は sshd を無効にしている」は誤り：tarball に `multi-user.target.wants/sshd.service` が既にある。リンクは足していない。
- 残り：新しいカードで ssh に入れるかの実機確認。いまのカードには展開不要（同じ内容を手で置いてある）。

### B. sway を GPU 描画に切り替える（未着手・任意）
- **何**：`start-sway`（`make_gui_stage.sh` が生成）の `WLR_RENDERER=pixman` を外し、`WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128` を与える。
- **なぜ**：panfrost は動いているが sway はまだ CPU 描画。
- **不確実な点**：表示先が simpledrm（リニアなダンプバッファのみ、モディファイア非対応）なので、wlroots が GPU で描いた画像を simpledrm に渡せるかは試すまで分からない。
- **手順**：画面を見ながら実機で `WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128 seatd-launch -- sway -d 2> /tmp/sway.log` を 1 回試す。出れば `start-sway` を直して gui tar を作り直す。出なければ pixman のまま（アプリ側の GLES は使える）。
- **戻し方**：環境変数を戻すだけ。

### C. `pacman -Syu`（任意。119 個の更新が待っている）
- 順序：`pacman -Syuw`（ダウンロードだけ。WiFi が詰まっても壊れない）→ `pacman -Su` → `pgrep sway; systemctl --failed` → `reboot`。
- 注意：tar で入れたユーザー空間（wpa_supplicant・iw・wireless-regdb・sway・mesa・python ほか）は pacman の管理外。共有ライブラリの版が上がって sway が起動しなくなったら gui tar を展開し直す（`make_gui_stage.sh` が rootfs のライブラリ有無を検証する）。「exists in filesystem」で止まったら tar のファイルとの衝突（`--overwrite` は最後の手段）。
- `linux-aarch64` 7.x が入っても rootfs 側の `/boot` に書かれるだけ。`/etc/pacman.conf` の `DisableSandboxFilesystem` は Landlock が入ったので戻してよい。

### D. WiFi：実機への大きなデータ送信で RK915 がエラーになる（回避中）
- **現象**：ホスト→実機に 53MB を送ると約 900KB で止まり、`rk915: fw error recovery (0) start` → `tx_thread: ret = -16` → `requesting mac80211 restart`。再起動直後に 1MB/s に絞っても 5 分で 16.5MB、その間に recovery 17 回。実機→ホストの採取や小さなコマンドは問題ない。
- **回避**：Image・DTB・tar の反映はカードを PC に挿して行う（§3）。
- **直すなら**：`rk915/` の受信経路（ROCKNIX PR #3251 の dw_mmc 割り込み対策、#3252 の修正）を調べる。§10.13 の「既知の問題」に該当。

### E. 前からある整理事項（急がない）
- ボタン・スティックへのキー割り当て（今は USB キーボード前提の `Alt+k` など）。
- 音量ボタン（SARADC ch2）の反応確認。DT の `adc-keys` は入っているが実機で押して未確認。
- 音声（I2S1 + RK817 codec）未検証。
- 起動オプション `clk_ignore_unused pd_ignore_unused regulator_ignore_unused` と earlycon の `115200n8` が本当に要るか（§10.9）。
- 「表示なし版」DTB（`rk3326-r36ultra-nodisp.dts`）を正式な名前にする。
- 表示の再初期化方式のために入れたドライバ変更は、2026-09-30 に `experiment/dsi-reinit` へ退避した。使うことになったら、注記の未検証の断定を直す（§10.12）。
- `r36ultra` でビルドした Image・DTB・wifi tar を実機で確認する（再初期化方式の変更を外したので Image が変わっている。リリース名も変わるので `scripts/deploy_sd.sh` で一式を入れる）。
- 純正 DT との残差分：`regulator-initial-mode`、USB のホスト専用化と VBUS スイッチ（GPIO3 A4。いまは ODROID-Go 由来の `vcc_host` GPIO0 B7 で動いている）。
- screenfetch の `GPU:` が空（lspci/glxinfo 前提のため。見た目だけ）。
- `/root/.bash_profile` が無く、ログインシェルは `.bashrc` を読まない（バナーは出ているので実害なし）。

### F. 配布に向けた変更（2026-09-30 実装、実機未確認）
- **WiFi の MAC**：DT の `local-mac-address` を削除（旧値は SoC シリアルから作っていたので公開しない）。rk915 に `macaddr` パラメータを追加（優先順位はパラメータ → DT → 乱数）。rootfs の `r36u-wlan-mac.service`（sysinit、udev より前）が `/etc/machine-id` の SHA-256 から局所管理・ユニキャストの MAC を作り、`/run/modprobe.d/r36u-wlan-mac.conf` に書く。**ユーザー空間から後で MAC を変える方式は不可**：rk915 は wlan0/p2p0 を `vif_macs` との一致で探す（`utils.c` の `find_main_iface`）。PC 上でスクリプトの計算は確認済み（同じ ID で同じ値、局所管理ビット）。
- **初期パスワード**：`r36u-default-password.service`（`ConditionFirstBoot=yes`）が `/dev/kmsg` に警告を書く。**空の `/etc/machine-id` は初回起動と判定されない**（machine-id(5) の規則 4）ので、新しいカードでは `uninitialized` の 1 行にする（README）。既存のカードでは出ない。
- 残り：実機で MAC が付くか（`/sys/module/rk915/parameters/macaddr`、`ip link`）、起動し直して同じか、新しいカードで警告が出るか。いまのカードは MAC が変わるので DHCP の IP も変わる。

## 2. 実機にだけ手で置いてある設定（新カードで再現しない）

| 場所 | 内容 | 扱い |
|---|---|---|
| `/etc/ssh/sshd_config.d/10-r36ultra.conf` | root のパスワードログイン許可 | A で stage に入れた。sshd の有効化リンクは rootfs の tarball に元からある |
| `/etc/pacman.conf` | `DisableSandboxFilesystem` を有効化（Landlock 無しの暫定策） | 戻してよい |
| `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` | 接続先 SSID とパスフレーズ | 意図どおり実機で設定（tar には入れない。展開時は `--exclude='./etc/wpa_supplicant/*'`） |
| `/root/.bashrc` | `bash /boot/firmware/screenfetch.sh` | 個人設定 |
| `/etc/fstab` | `/boot/firmware` | §7.7 の手順に入っている |

## 3. 運用メモ（今回の教訓）

- **カードへの反映は PC に挿して行い、同期は `sync -f <マウント先>` だけ使う。** 引数なしの `sync` は WSL の死んだ 9p マウント（Google Drive の G:）で永久に止まる（9 時間止まった）。`echo 3 > drop_caches` も全 superblock を走査するので同様に避ける。書いた後は umount → 読み直して `cmp`。
- ssh は小さなコマンドと実機→ホストの採取に限る（D）。
- `pgrep -f` / `pkill -f` は自分のシェルのコマンドラインにも一致する。止めるときは `ps` で PID を見て直接 kill。
- `poweroff` は ssh から打てて電源が切れる（`system-power-controller` の効果）。
- 電池残量は 9/30 に満充電で較正済み。USB を抜いて 1 時間後の % を一度見ておくと妥当性が分かる。
- 電池ゲージが止まって見えたら RTC を疑う（RK817 の RTC が止まっていると電圧・電流が更新されない。`RTC_DRV_RK808` が RTC を走らせる）。

## 4. 前のセッションのスクラッチ（2026-09-30 に救出済み）

`local/rescued_scratch/` に丸ごと写した。反映用の 4 本は構成に合わせて直し、`scripts/` に置いた（`deploy_sd_v3.sh` → `deploy_sd.sh`、`deploy_sd_v4.sh` → `deploy_image.sh`、`deploy_gui.sh`、`finish_check.sh`。構成変更後は未実行）。ほかに `verify18.sh`・`verify19.sh`・`dev_regs.sh`（ssh で実機を検証）、`throttle.py`（D の試験）、`dosfstools/`（実機用 `fsck.fat`）、旧 sshd パッチがある。

## 5. GitHub 公開の残作業

構成は 2026-09-30 に変更済み（`README.md`、`.gitignore`）。公開先は `rei512/r36ultra-archlinux`（`main`）と `rei512/rk915`（`main`）。

- **push 前に再検査**：SSID・BSSID・IP・MAC・SoC シリアルは削除済み。手元のコミットは push 前に 1 つにまとめ、古いパッチ（MAC 入り）を履歴に残さない。
- 配布するバイナリのビルドパスは相対にした（`-ffile-prefix-map`。両 tar で `/home/` は 0 件）。
- 自作部分は MIT（`LICENSE`、各ファイルに SPDX）。
- `rk915` のファームウェア blob のライセンスは未確認（上流の `main` に既にある）。
- `DIFF_REPORT.md` は純正 DTB の内容を多く含むので公開しない（2026-09-30 に `reference/` へ移した）。
- README で「準備中」の扱いにしていないが未整備のもの：Releases のイメージ、パッケージの対象一覧、SD カードのイメージ作成スクリプト。
