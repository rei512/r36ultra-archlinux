# R36Ultra にメインライン Linux を入れる

## この文書について

この文書は、市販のゲーム機 **R36Ultra** に自分でビルドした **Linux カーネル (v6.19)** を入れて起動するまでの全工程を記録したものです。

### 対象読者

「Linux は使ったことがあるが、カーネルをビルドしたことはない」レベルの人を想定しています。組み込み Linux 特有の概念（デバイスツリー、クロスコンパイル、U-Boot など）は初出時に解説します。

### 到達点

画面にテキストのログインプロンプトが表示される状態（GUI なし）。

### 作業環境

- Windows 11 + WSL2 (Ubuntu)
- クロスコンパイラ: `aarch64-linux-gnu-gcc` (Ubuntu 13.3.0)

### パスの読み替え

2026-09-30 にディレクトリ構成を変えた。本文のパスは変更前のもので、今は次の場所にある。

| 本文のパス | 今のパス |
|---|---|
| `linux-6.19/` | `kernel/linux-6.19/` |
| `rk915/` | `modules/rk915/` |
| `wvkbd/` | `userspace/wvkbd/` |
| `r36u_joyd.c` | `userspace/r36u-joyd/r36u_joyd.c` |
| `r36u_statusd.c` | `userspace/r36u-status/r36u_statusd.c` |
| `make_*.sh`、`fetch_pkgs.py` | `scripts/` |
| `extlinux.conf`、`boot.ini` | `boot/` |
| `diag_init.c` | `tools/diag_init/` |
| `pkgs/`、`sysroot/`、`wifi_stage/`、`gui_stage/`、`ArchLinuxARM-aarch64-latest.tar.gz` | `build/` |
| `r36u/`、`arkos/`、`dts_decompiled/` | `reference/` |
| スクリプト内のヒアドキュメントで書いていた設定ファイル | `rootfs/overlay/wifi/`、`rootfs/overlay/gui/` |

---

## 1. 組み込み Linux の起動の仕組み

この章はすべて概念の説明です。コマンドは出てきません。ここで全体像を掴んでから、次章以降の実作業に進みます。

### 1.1 PC との比較で理解する起動シーケンス

普段使っている PC と、今回の R36Ultra では、電源を入れてからログインプロンプトが出るまでの流れが異なります。

```
【PC の場合】
  電源ON → BIOS/UEFI → GRUB → Linux カーネル → systemd → ログイン

【組み込み (R36Ultra) の場合】
  電源ON → BootROM → U-Boot → Linux カーネル → systemd → ログイン
```

それぞれの役割を説明します。

**BootROM** — SoC (後述) の中にある読み取り専用の小さなプログラムです。電源が入ると最初にこれが動きます。BootROM は eMMC（内蔵フラッシュ）や SD カードの先頭を読み、次に起動すべきプログラム（U-Boot）を探してメモリに読み込みます。PC でいう BIOS/UEFI に相当しますが、はるかに小さく機能も限定的です。BootROM はユーザーが書き換えることはできません。

**U-Boot** — PC でいう GRUB に相当するブートローダです。BootROM から制御を渡されると、SD カードや eMMC から Linux カーネルとデバイスツリー（後述）をメモリに読み込み、カーネルに制御を渡します。ARM SoC の世界ではほぼ標準のブートローダです。

R36Ultra の eMMC には、購入時点で **ODROID-Go2 互換の U-Boot** がインストールされています。このU-Boot は SD カードを eMMC より優先して読むため、SD カードに正しい形式でカーネルを置けば、eMMC の中身を一切変更せずに自分の Linux を起動できます。

> **訂正（2026-09-22、実機ログで確認）：** 実際に入っていたのは **Rockchip RK3326 EVB 系（EmuELEC 由来）の U-Boot 2017.09** で、ODROID-Go2 互換ではありません。eMMC から起動した後に SD カードの `extlinux/extlinux.conf` を読む動作は同じなので、この章の起動方式自体は有効です。詳細は §10.3。

**Linux カーネル** — OS の中核です。ハードウェアの制御、メモリ管理、プロセス管理などを担当します。PC 用の Linux カーネルと組み込み用の Linux カーネルはソースコードは同じですが、ビルド時に有効にするドライバやオプションが異なります。

**systemd** — カーネルが起動した後、ユーザー空間で最初に動くプログラム（init）です。各種サービスの起動、ログインプロンプトの表示などを担当します。

### 1.2 SoC とは

**SoC (System on Chip)** は、CPU、GPU、メモリコントローラ、各種 I/O コントローラなどを 1 つのチップにまとめたものです。PC では CPU、チップセット、GPU がそれぞれ別のチップですが、スマートフォンやゲーム機のような小型デバイスでは 1 チップに統合されています。

R36Ultra に搭載されている **RK3326** は Rockchip 社の SoC で、以下のような構成です：

- CPU: ARM Cortex-A35 × 4コア (最大 1.5GHz)
- GPU: Mali-G31
- ディスプレイ出力: MIPI DSI (後述)
- ストレージインターフェース: eMMC, SD カード
- オーディオ: I2S
- ADC: SARADC (アナログ入力、ジョイスティック等に使用)
- その他: UART, SPI, I2C, GPIO, PWM...

### 1.3 デバイスツリー (Device Tree) とは

PC では、OS が起動するときに ACPI というしくみでマザーボード上のハードウェア構成を自動検出します。しかし組み込みデバイスには ACPI がありません。代わりに **デバイスツリー** というデータファイルで、ボード上にどんなハードウェアがどのアドレスに接続されているかをカーネルに教えます。

デバイスツリーには 3 つの形式があります：

| 拡張子 | 名前 | 内容 |
|--------|------|------|
| `.dts` | Device Tree Source | 人間が読み書きするテキスト形式 |
| `.dtsi` | Device Tree Source Include | 他の DTS から読み込まれる共有定義 |
| `.dtb` | Device Tree Blob | コンパイル済みのバイナリ形式（実際にカーネルが読む） |

テキスト (`.dts`) を **dtc** (Device Tree Compiler) というツールでコンパイルすると、バイナリ (`.dtb`) になります。

```
DTS (テキスト) ──dtc──→ DTB (バイナリ)
```

DTS は階層的にインクルード（読み込み）できます。R36Ultra の場合：

```
rk3326.dtsi                        ← SoC の定義（CPU, メモリコントローラ, GPIO 等）
                                      Rockchip が提供。全 RK3326 ボードで共通。
  └─ rk3326-odroid-go.dtsi         ← ボード共通の定義（PMIC, SD カード, 画面接続等）
                                      ODROID-Go Advance 用にメインラインに入っている。
      └─ rk3326-r36ultra.dts       ← R36Ultra 固有の定義（パネル種類, GPIO ピン）
                                      ★ 今回自分で作るファイル
```

**なぜデバイスツリーを自分で書く必要があるか：** メインラインカーネルには R36Ultra 用の DTS が存在しないからです。しかし、同じ SoC (RK3326) と同じ PMIC (RK817) を使う ODROID-Go Advance 用の DTSI はメインラインに含まれているため、それを継承して R36Ultra 固有の部分（パネルの種類や GPIO の割り当て）だけを記述すれば済みます。

### 1.4 クロスコンパイルとは

R36Ultra の CPU は **ARM Cortex-A35** で、命令セットは **AArch64** (ARM 64bit) です。一方、作業に使う PC の CPU は x86_64 です。命令セットが異なるため、PC で普通にコンパイルしても R36Ultra では動きません。

**クロスコンパイル** とは、自分の CPU とは異なる CPU 向けのバイナリを生成するコンパイルのことです。これには**クロスコンパイラ**（他アーキテクチャ向けのコンパイラ）を使います。

```
PC (x86_64)                      R36Ultra (AArch64)
┌───────────────┐                ┌──────────────────┐
│ ソースコード    │                │                  │
│    ↓           │                │                  │
│ aarch64-linux- │   SD カード    │ ARM Cortex-A35   │
│ gnu-gcc        │ ──────────→   │ が実行            │
│    ↓           │                │                  │
│ ARM用バイナリ   │                │                  │
└───────────────┘                └──────────────────┘
```

Ubuntu では以下のパッケージでクロスコンパイラをインストールできます：

```bash
sudo apt-get install gcc-aarch64-linux-gnu
```

Linux カーネルのビルドでは、以下の 2 つの変数でクロスコンパイルを指定します：

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- ...
```

- `ARCH=arm64` — ターゲットアーキテクチャ。カーネルに「ARM 64bit 向けにビルドしろ」と伝える
- `CROSS_COMPILE=aarch64-linux-gnu-` — コンパイラの接頭辞。`gcc` の代わりに `aarch64-linux-gnu-gcc` が使われる

### 1.5 カーネルコンフィグとは

Linux カーネルには数万のオプション（ドライバ、機能）があります。すべてを有効にすると巨大になるので、ターゲットデバイスに必要なものだけを選んでビルドします。

この選択結果はソースツリーのルートにある **`.config`** というファイルに保存されます。例：

```
CONFIG_DRM_ROCKCHIP=y       ← Rockchip の画面出力ドライバを有効
CONFIG_FRAMEBUFFER_CONSOLE=y ← 画面にテキストコンソールを表示
# CONFIG_WIFI is not set     ← WiFi は無効
```

各オプションには 3 つの状態があります：

| 状態 | 意味 |
|------|------|
| `=y` | カーネル本体に組み込む。起動直後から使える |
| `=m` | モジュール（別ファイル）としてビルド。必要時に読み込む |
| 未設定 | ビルドしない |

**defconfig** — 各アーキテクチャには「これで大体動く」というデフォルト設定が用意されています。`arm64` の defconfig は多くの ARM64 ボードで動くように作られており、RK3326 のサポートも含まれています。これをベースにして、足りないオプションだけ追加するのが一般的なやり方です。

今回は `=y`（組み込み）を使います。`=m`（モジュール）にすると、起動時にモジュールを読み込むための **initramfs**（初期 RAM ファイルシステム）が必要になり、構成が複雑になるためです。

### 1.6 SD カードの構造と起動の流れ

U-Boot は SD カードの先頭パーティション（FAT32）から `extlinux/extlinux.conf` というファイルを探します。これは PC でいう GRUB の `grub.cfg` に相当する設定ファイルで、「どのカーネルをどう起動するか」が書いてあります。

```
SD カード
├── パーティション 1 (FAT32, 256MB) ← U-Boot がここを読む
│   ├── extlinux/extlinux.conf       ← ブート設定ファイル
│   ├── Image                        ← Linux カーネル本体
│   └── rk3326-r36ultra.dtb          ← デバイスツリー（バイナリ）
│
└── パーティション 2 (ext4, 残り)    ← Linux が rootfs としてマウント
    ├── bin/                          ← 基本コマンド
    ├── etc/                          ← 設定ファイル
    ├── usr/                          ← ユーザーランドプログラム
    └── ...                           ← Arch Linux ARM のファイル群
```

**なぜ FAT32 か：** U-Boot が確実に読めるファイルシステムだからです。ext4 も読めますが、FAT32 が最も互換性が高い。

**rootfs とは：** カーネル起動後の Linux の「中身」です。コマンド (`/bin/ls`, `/bin/bash` 等)、ライブラリ (`/lib/`)、設定ファイル (`/etc/`) など、ユーザーが使うものはすべてここに入っています。今回は **Arch Linux ARM** の Generic AArch64 tarball を使います。

**起動の全体フロー：**

```
電源 ON
  ↓
BootROM (RK3326 内蔵)
  ↓  eMMC から U-Boot を読み込む
U-Boot
  ↓  SD カードの FAT32 パーティションから extlinux.conf を読む
  ↓  Image (カーネル) と DTB をメモリに配置
  ↓  カーネルに制御を渡す
Linux カーネル
  ↓  DTB を解析してハードウェアを初期化
  ↓  SD カードの ext4 パーティションを rootfs としてマウント
  ↓  /sbin/init (systemd) を起動
systemd
  ↓  各種サービスを起動
ログインプロンプト表示 ← ★ここが今回の目標
```

---

## 2. ターゲットハードウェアの調査

### 2.1 なぜ調査が必要か

前章で説明したように、メインラインカーネルには R36Ultra 用のデバイスツリーが存在しません。自分で DTS を書くには、ボード上のハードウェア構成を正確に知る必要があります：

- ディスプレイパネルの型番・解像度・接続方式
- 各部品が SoC のどの GPIO ピンに接続されているか
- 電源管理 IC (PMIC) の型番とレギュレータ構成
- その他の周辺機器（WiFi、ジョイスティックなど）

幸い、R36Ultra にはストックファームウェアと ArkOS（コミュニティ製ゲーム OS）が入っており、それぞれの DTB ファイルが手に入ります。これを逆コンパイルすれば設計情報を読み取れます。

### 2.2 DTB の逆コンパイル

DTB（バイナリ）を DTS（テキスト）に戻すには、`dtc` を使います：

```bash
dtc -I dtb -O dts -o r36u_stock.dts  r36u_stock.dtb
#    ^^^^^ ^^^^^    ^^^^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^^^
#    入力形式 出力形式  出力ファイル名     入力ファイル名
```

- `-I dtb` — 入力がバイナリ形式 (DTB) であることを指定
- `-O dts` — 出力をテキスト形式 (DTS) にすることを指定

以下の 4 つの DTB を逆コンパイルしました：

| ファイル | 出典 | 用途 |
|----------|------|------|
| `r36u_stock.dts` | ストックファームウェア | ハードウェア情報の主要参照元 |
| `arkos_main.dts` | ArkOS メイン DTB | 動作実績のある設定の確認 |
| `arkos_panel1.dts` | ArkOS パネル1 | パネル設定のバリエーション確認 |
| `arkos_panel5.dts` | ArkOS パネル5 | 同上 |

なぜ複数のDTBを調べるのか：ストックと ArkOS の両方を確認することで、共通している設定（=ハードウェアの実態に基づく設定）と、ソフトウェア固有の設定を区別できます。

### 2.3 DTB から読み取ったハードウェア情報

以下、BSP DTB の該当箇所を引用しながら解説します。

#### ディスプレイパネル

```dts
/* r36u_stock.dts より抜粋 */
panel@0 {
    compatible = "sitronix,st7703\0simple-panel-dsi";
    dsi,lanes = <0x04>;              /* 4レーン */
    reset-gpios = <0x66 0x1b 0x01>; /* GPIO3 RK_PD3, active-low */

    display-timings {
        timing0 {
            clock-frequency = <0x2aea540>; /* 44,958,016 Hz ≈ 45MHz */
            hactive = <0x2d0>;             /* 720 ピクセル */
            vactive = <0x2d0>;             /* 720 ピクセル */
            hfront-porch = <0x8c>;         /* 140 */
            hsync-len = <0x50>;            /* 80 */
            hback-porch = <0x8c>;          /* 140 */
            vfront-porch = <0x14>;         /* 20 */
            vsync-len = <0x04>;            /* 4 */
            vback-porch = <0x14>;          /* 20 */
        };
    };
};
```

**読み取った情報：**
- **コントローラ IC:** Sitronix ST7703 — MIPI DSI 接続の液晶パネルコントローラ
- **解像度:** 720 × 720 ピクセル（正方形）
- **クロック:** 約 45MHz
- **接続:** 4 レーン MIPI DSI

**用語解説：**

- **MIPI DSI (Mobile Industry Processor Interface - Display Serial Interface)** — スマートフォンやタブレットで標準的に使われるディスプレイ接続規格。SoC とパネルを高速シリアル信号で接続します。「4 レーン」= データ転送用の信号線が 4 本あること。レーン数が多いほど高帯域。
- **GPIO (General Purpose Input/Output)** — 汎用入出力ピン。SoC から外部デバイスに信号を送ったり受けたりするためのピン。パネルのリセット信号や電源制御に使います。

**GPIO の読み方 — phandle の解決：**

BSP の DTB では GPIO が `<0x66 0x1b 0x01>` のような数値で記述されています。これを人間が読める形に変換します：

```
<0x66 0x1b 0x01>
  │     │     └─ 0x01 = GPIO_ACTIVE_LOW（Low でアクティブ）
  │     └─ 0x1b = 27 → RK_PD3（ポート D、ビット 3）
  └─ phandle 0x66 → DTB 内でこの値を持つノードを探す → gpio3
```

- **phandle** — DTB 内でノード（デバイス定義）を参照するための数値 ID。逆コンパイルした DTS を検索して `phandle = <0x66>` を持つノードを探すと、それが `gpio3` (GPIO バンク 3) であることがわかります。
- **RK_PD3** — Rockchip の GPIO 命名規則：`RK_P` + ポート文字 (A=0, B=1, C=2, D=3) + ビット番号。0x1b = 27 = 8×3 + 3 → ポート D、ビット 3。
- **active-low** — 信号が Low (0V) のときに「有効」。パネルをリセットするには GPIO を Low にします。

#### パネル電源

```dts
/* r36u_stock.dts より */
vcc18_lcd_n: regulator@... {
    /* GPIO3 RK_PA3 (active-high) で制御される固定 1.8V レギュレータ */
    gpio = <&gpio3 RK_PA3 GPIO_ACTIVE_HIGH>;
    enable-active-high;
};
```

パネルの電源 (IOVCC/VCC) は GPIO で ON/OFF する固定電圧レギュレータで供給されています。

#### バックライト

```dts
backlight {
    compatible = "pwm-backlight";
    pwms = <&pwm1 0 25000 0>;
    /*       ^^^^ ^ ^^^^^
     *       PWM1  ch0  周期25000ns = 40kHz */
};
```

- **PWM (Pulse Width Modulation, パルス幅変調)** — デジタル信号の ON/OFF の比率（デューティ比）を変えることで、アナログ的な制御を行う方式。バックライト LED の明るさを 0〜100% で制御するのに使います。
- 周期 25000 ナノ秒 = 40kHz の PWM 信号

#### PMIC (電源管理 IC)

```dts
pmic@20 {
    compatible = "rockchip,rk817";
    /* ... */
};
```

**PMIC (Power Management IC)** — ボード上の各部品に必要な電圧を供給する IC です。CPU には 1.0V、メモリには 1.8V、SD カードには 3.3V...というように、それぞれ異なる電圧が必要で、PMIC がこれをすべて管理しています。

R36Ultra は **RK817** を使用しています。これは ODROID-Go Advance と同じチップで、メインラインカーネルに完全にサポートされています。レギュレータ構成：

| レギュレータ | 用途 | 電圧 |
|-------------|------|------|
| DCDC_REG1 | vdd_logic (ロジック) | 950 〜 1150 mV |
| DCDC_REG2 | vdd_arm (CPU) | 950 〜 1350 mV |
| DCDC_REG3 | vcc_ddr (メモリ) | 固定 |
| DCDC_REG4 | vcc_3v0 | 3.0V |
| LDO_REG1〜9 | 各種 I/O | 個別設定 |

#### WiFi

```dts
wireless-wlan {
    wifi_chip_type = "rk915";
};
```

WiFi チップは **RK915** ですが、メインラインカーネルにはこのチップのドライバがありません。今回は無効化します。

#### ジョイスティック

BSP では `play_joystick` という独自ドライバを使っており、SARADC（逐次比較型 ADC）の 4 チャンネルでアナログスティック 2 本の入力を読み取っています。メインラインの `adc-joystick` ドライバで代替可能ですが、今回は未設定です。

### 2.4 調査結果のまとめ

| 項目 | 情報 | メインラインサポート |
|------|------|---------------------|
| SoC | RK3326 (Cortex-A35 x4) | あり |
| PMIC | RK817 | あり (ODROID-Go と同じ) |
| パネル | ST7703, 720x720, MIPI DSI 4lane | ドライバあり (ST7703)、初期化シーケンスは要確認 |
| パネルリセット GPIO | gpio3 RK_PD3, active-low | — |
| パネル電源 GPIO | gpio3 RK_PA3, active-high | — |
| バックライト | PWM1, 25000ns | あり |
| WiFi | RK915 | **なし** |
| ジョイスティック | SARADC 4ch | ドライバあり (adc-joystick)、DTS 未設定 |
| U-Boot | eMMC 上、RK3326 EVB 系（EmuELEC）。`extlinux.conf` を読む | そのまま使える（§10.3） |
| デバッグ UART | **UART5**（0xff178000）、**1,500,000 baud** | mainline では `ttyS0`（§10.3） |

---

## 3. 戦略の決定 — 最小限の変更で起動を目指す

### 3.1 カーネルの選択肢

Linux カーネルを入手するには大きく 2 つの選択肢があります：

| 選択肢 | メリット | デメリット |
|--------|---------|-----------|
| **Rockchip BSP カーネル** (4.x/5.x) | R36Ultra を完全サポート。ストックファームウェアがこれで動いている | バージョンが古い (4.4 系等)。独自パッチが多数あり保守が困難 |
| **メインラインカーネル** (6.19) | 最新バージョン。クリーンなコード。コミュニティの継続的サポート | R36Ultra 用の DTS がない。一部ドライバ未対応 (WiFi 等) |

**判断: メインラインを選択。** 理由：
- RK3326 のサポート（CPU、GPU、DSI、SDMMC 等）はメインラインに入っている
- ST7703 パネルドライバもメインラインに入っている
- ODROID-Go 系の DTSI（RK817 PMIC 含む）もメインラインに入っている
- つまり、DTS を 1 ファイル作るだけで動く見込みがある

**なぜ v6.19 か:** 作業時点 (2026 年 2 月) の最新安定版。

### 3.2 パネルドライバの戦略

メインラインの ST7703 パネルドライバ (`panel-sitronix-st7703.c`) には、いくつかのパネル定義が含まれています。その中に **Powkiddy RGB30** のパネルがあります：

- RGB30: 同じ ST7703 コントローラ、同じ 720×720 解像度
- ただし**初期化シーケンス**（パネル IC に送るコマンド列）は機種ごとに異なる

**初期化シーケンスとは：** LCD パネルのコントローラ IC は、電源投入後に特定のコマンドを決まった順番で送らないと正しく表示されません。このコマンド列はパネルメーカーが提供するもので、パネルの型番が違えばシーケンスも違います。

**判断:** まずは RGB30 パネルの設定をそのまま使って「映るかどうか」を確認する。もし映らなければ、BSP DTB に記載されている R36Ultra 固有の初期化シーケンス（数百バイトのバイナリデータ）を C コードに変換してドライバに追加する。

### 3.3 DTS の設計方針

```
rk3326-odroid-go.dtsi を継承して、最小限だけ上書きする
```

**なぜ ODROID-Go ベースか：** R36Ultra は ODROID-Go Advance と同じ RK3326 + RK817 構成です。DTSI には以下の共通部分が定義済み：
- RK817 PMIC の全レギュレータ設定
- SD カードコントローラ (SDMMC)
- UART2（シリアルコンソール）
- MIPI DSI ホスト
- PWM バックライト
- USB

**上書きが必要なのはこれだけ：**
- `model` / `compatible` 文字列（機種名の宣言）
- パネルの `compatible`（どのパネルドライバを使うか）
- パネルのリセット GPIO（ODROID-Go と R36Ultra でピンが異なる）
- パネルの電源レギュレータ（GPIO で ON/OFF する固定レギュレータ）

---

## 4. カーネルソースの準備

### 4.1 ソースの入手

Linux 6.19 のソースを GitHub から tarball (`.tar.gz`) でダウンロードし、展開しました。

```bash
# tarball を展開
tar -xzf linux-6.19.tar.gz
cd linux-6.19
```

> **重要な教訓：** この方法には後述する深刻な問題があります。可能であれば `git clone` を使うべきです。`git clone` ではシンボリックリンクが正しく保持されますが、GitHub の tarball/zip ではシンボリックリンクがテキストファイルに変換されてしまいます。

### 4.2 GitHub tarball 特有の問題と対処（重要な落とし穴）

Linux カーネルのソースツリーには**シンボリックリンク**（別のファイルへのポインタ）が多数含まれています。Git リポジトリではこれが正しく管理されますが、GitHub の zip/tar アーカイブでは**リンク先のパスが書かれたただのテキストファイル**に変換されてしまいます。

例えば、本来は：

```
arch/arm64/tools/syscall_64.tbl → ../../../scripts/syscall.tbl (シンボリックリンク)
```

であるべきところが、GitHub tarball では：

```
arch/arm64/tools/syscall_64.tbl (通常ファイル、中身は "../../../scripts/syscall.tbl" という文字列)
```

になっています。これが原因で様々なビルドエラーが発生しました。以下、発生順に記録します。

---

#### 問題 1: `cc-version.sh: Permission denied`

**症状:**
```
make defconfig
  Sorry, this C compiler is not supported.
```

**原因:** tarball を展開すると、シェルスクリプトの実行権限 (`+x`) が失われていた。`scripts/cc-version.sh` が実行できず、コンパイラの検出に失敗した。

**修正:**
```bash
find scripts/ -name "*.sh" -exec chmod +x {} \;
chmod +x scripts/cc-version.sh
```

**教訓:** tarball 展開後は、スクリプトの実行権限を確認すること。

---

#### 問題 2: `__NR_gettimeofday undeclared`

**症状:**
```
error: '__NR_gettimeofday' undeclared
```
カーネルビルド中に、システムコール番号の定義が見つからないというエラー。

**原因の追跡:**

1. `__NR_gettimeofday` は `arch/arm64/include/generated/uapi/asm/unistd_64.h` で定義されるはず
2. このヘッダはビルド時に `arch/arm64/tools/syscall_64.tbl` から自動生成される
3. `syscall_64.tbl` を確認すると...ファイルサイズが 36 バイトしかない
4. 中身は `../../../scripts/syscall.tbl` という文字列 — シンボリックリンクが壊れていた
5. 結果、生成された `unistd_64.h` はわずか 9 行しかなかった（本来は 335 行）

**修正:**
```bash
cd arch/arm64/tools/
rm syscall_64.tbl
ln -s ../../../scripts/syscall.tbl syscall_64.tbl
#     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
#     正しいシンボリックリンクを手動で作成
```

その後、ヘッダファイルを再生成：
```bash
sh ./scripts/syscallhdr.sh \
    --emit-nr \                                    # __NR_ マクロを出力
    --abis common,64,renameat,rlimit,memfd_secret \ # ABI フィルタ
    arch/arm64/tools/syscall_64.tbl \              # 入力: システムコール一覧表
    arch/arm64/include/generated/uapi/asm/unistd_64.h  # 出力: ヘッダファイル
```

再生成後は 335 行の正しいヘッダが生成されました。

---

#### 問題 3: `vdso_offset_sigtramp undeclared`

**症状:**
```
error: 'vdso_offset_sigtramp' undeclared
```

**原因:** `include/generated/vdso-offsets.h` が空ファイルだった。このヘッダはビルド中に `arch/arm64/kernel/vdso/gen_vdso_offsets.sh` で自動生成されるが、このスクリプトが実行権限を持っていなかったため、空のファイルが生成された。

**vDSO とは:** Virtual Dynamic Shared Object の略。カーネルがユーザー空間に公開する小さな共有ライブラリで、`gettimeofday()` のようなよく使うシステムコールを高速に実行するためのしくみです。

**修正:**
```bash
chmod +x arch/arm64/kernel/vdso/gen_vdso_offsets.sh

# 手動でヘッダを生成
aarch64-linux-gnu-nm arch/arm64/kernel/vdso/vdso.so.dbg \
    | sh arch/arm64/kernel/vdso/gen_vdso_offsets.sh \
    > include/generated/vdso-offsets.h
```

生成結果：
```c
#define vdso_offset_sigtramp 0x0810
```

---

#### 問題 4: DTB コンパイル — `gpio.h: No such file or directory`

**症状:**
```
fatal error: dt-bindings/gpio/gpio.h: No such file or directory
```

**原因:** DTB のコンパイル時に、gcc がプリプロセッサとして DTS を処理する際のインクルードパスとして `scripts/dtc/include-prefixes/` が使われる。このディレクトリ内の全エントリ（12 個）がシンボリックリンクであるべきところ、テキストファイルになっていた。

**修正:** 12 個すべてを正しいシンボリックリンクに再作成：
```bash
cd scripts/dtc/include-prefixes/

# テキストファイルを削除してシンボリックリンクを作成
rm arc arm arm64 dt-bindings microblaze mips nios2 openrisc powerpc riscv sh xtensa

ln -s ../../../arch/arc/boot/dts arc
ln -s ../../../arch/arm/boot/dts arm
ln -s ../../../arch/arm64/boot/dts arm64
ln -s ../../../include/dt-bindings dt-bindings     # ← これが最も重要
ln -s ../../../arch/microblaze/boot/dts microblaze
ln -s ../../../arch/mips/boot/dts mips
ln -s ../../../arch/nios2/boot/dts nios2
ln -s ../../../arch/openrisc/boot/dts openrisc
ln -s ../../../arch/powerpc/boot/dts powerpc
ln -s ../../../arch/riscv/boot/dts riscv
ln -s ../../../arch/sh/boot/dts sh
ln -s ../../../arch/xtensa/boot/dts xtensa
```

---

#### 問題 5: DTB コンパイル — `linux-event-codes.h syntax error`

**症状:**
```
Error: ./scripts/dtc/include-prefixes/dt-bindings/input/linux-event-codes.h:1.1-3 syntax error
FATAL ERROR: Unable to parse input tree
```

**原因:** 問題 4 を修正した後に発生。`include/dt-bindings/input/linux-event-codes.h` もシンボリックリンクが壊れていた。中身は `../../uapi/linux/input-event-codes.h` という文字列。

gcc のプリプロセス段階では C の `#include` が処理されるので問題ないが、その結果の DTS の中にパス文字列がそのまま埋め込まれてしまい、dtc がパースに失敗した。

**修正:**
```bash
cd include/dt-bindings/input/
rm linux-event-codes.h
ln -s ../../uapi/linux/input-event-codes.h linux-event-codes.h
```

---

#### まとめ: `git clone` を使えばこれらの問題は全て起きない

| # | 症状 | 根本原因 |
|---|------|----------|
| 1 | Permission denied | 実行権限の喪失 |
| 2 | `__NR_gettimeofday` undeclared | syscall_64.tbl のリンク切れ |
| 3 | `vdso_offset_sigtramp` undeclared | gen_vdso_offsets.sh の権限喪失 |
| 4 | `gpio.h` not found | include-prefixes のリンク切れ (12個) |
| 5 | `linux-event-codes.h` syntax error | dt-bindings 内のリンク切れ |

**全て GitHub tarball のシンボリックリンク問題が原因です。** `git clone` を使えばこれらは発生しません。

---

## 5. デバイスツリー (DTS) の作成

### 5.1 作成したファイル

`linux-6.19/arch/arm64/boot/dts/rockchip/rk3326-r36ultra.dts` (41行)

> **注（2026-09-22）：** 以下は初期版です。実機デバッグの結果、レギュレータ・I/O 電圧・UART・パネル・入力デバイスなど多数の上書きが追加されました。現在の内容と各変更の根拠は §10.8 と `DIFF_REPORT.md` を参照してください。

```dts
// SPDX-License-Identifier: (GPL-2.0+ OR MIT)
/*
 * Device tree for R36Ultra handheld game console (RK3326)
 * Based on rk3326-odroid-go.dtsi
 */

/dts-v1/;
#include <dt-bindings/gpio/gpio.h>
#include <dt-bindings/pinctrl/rockchip.h>
#include "rk3326-odroid-go.dtsi"

/ {
	model = "R36Ultra";
	compatible = "rgameconsole,r36ultra", "rockchip,rk3326";

	/*
	 * Panel power: GPIO-controlled fixed 1.8V regulator.
	 * gpio3 RK_PA3 (active-high) enables the panel IOVCC.
	 */
	vcc18_lcd_n: regulator-vcc18-lcd {
		compatible = "regulator-fixed";
		regulator-name = "vcc18_lcd_n";
		regulator-boot-on;
		gpio = <&gpio3 RK_PA3 GPIO_ACTIVE_HIGH>;
		enable-active-high;
	};
};

/*
 * Override the panel node defined in rk3326-odroid-go.dtsi.
 * Using powkiddy,rgb30-panel as a first approximation (same ST7703
 * controller, same 720x720 resolution). Timings may need adjustment.
 * Reset GPIO: gpio3 RK_PD3 (active-low) per BSP DTS.
 */
&internal_display {
	compatible = "powkiddy,rgb30-panel";
	iovcc-supply = <&vcc18_lcd_n>;
	vcc-supply = <&vcc18_lcd_n>;
	reset-gpios = <&gpio3 RK_PD3 GPIO_ACTIVE_LOW>;
};
```

### 5.2 各行の解説

#### ヘッダ部分

```dts
/dts-v1/;
```
DTS のバージョン宣言。「バージョン 1 の DTS 構文を使う」という意味。全ての DTS ファイルの先頭に必要です。

```dts
#include <dt-bindings/gpio/gpio.h>
#include <dt-bindings/pinctrl/rockchip.h>
#include "rk3326-odroid-go.dtsi"
```

DTS は C プリプロセッサを通るため、`#include` が使えます。

- `<dt-bindings/gpio/gpio.h>` — `GPIO_ACTIVE_LOW`, `GPIO_ACTIVE_HIGH` などの定数を定義
- `<dt-bindings/pinctrl/rockchip.h>` — `RK_PA3`, `RK_PD3` などの Rockchip GPIO ピン名を定義
- `"rk3326-odroid-go.dtsi"` — ODROID-Go の共通定義を読み込む。PMIC、SDMMC、DSI、バックライトなどが定義済み

#### ルートノード

```dts
/ {
	model = "R36Ultra";
	compatible = "rgameconsole,r36ultra", "rockchip,rk3326";
```

`/` はデバイスツリーのルート（最上位）ノードです。

- `model` — 人間が読むための機種名
- `compatible` — **カーネルがドライバをマッチングするためのキー。** カーネルは起動時にこの文字列を見て、対応するボード固有の処理を探します。カンマの前がメーカー名、後がボード名です。複数指定した場合、左から順にマッチングを試みます。`"rockchip,rk3326"` はフォールバック。

#### パネル電源レギュレータ

```dts
	vcc18_lcd_n: regulator-vcc18-lcd {
		compatible = "regulator-fixed";
		regulator-name = "vcc18_lcd_n";
		regulator-boot-on;
		gpio = <&gpio3 RK_PA3 GPIO_ACTIVE_HIGH>;
		enable-active-high;
	};
```

BSP DTB で確認した「GPIO で制御する固定電圧レギュレータ」を定義しています。

- `vcc18_lcd_n:` — ノードのラベル（他のノードからこの名前で参照できる）
- `compatible = "regulator-fixed"` — 固定電圧レギュレータ用の汎用ドライバを使う
- `regulator-boot-on` — 起動時に有効にする（パネルに電源が必要なため）
- `gpio = <&gpio3 RK_PA3 GPIO_ACTIVE_HIGH>` — GPIO3 のポート A ビット 3 を High にすると電源 ON
- `enable-active-high` — High で有効化

#### パネルノードのオーバーライド

```dts
&internal_display {
	compatible = "powkiddy,rgb30-panel";
	iovcc-supply = <&vcc18_lcd_n>;
	vcc-supply = <&vcc18_lcd_n>;
	reset-gpios = <&gpio3 RK_PD3 GPIO_ACTIVE_LOW>;
};
```

`&internal_display` の `&` は「既に定義されているノードを参照して上書きする」という構文です。`internal_display` は `rk3326-odroid-go.dtsi` の中で定義されたパネルノードのラベルで、ここでは以下のプロパティだけを上書きしています：

- `compatible = "powkiddy,rgb30-panel"` — RGB30 のパネルドライバを使う（第 3 章で説明した戦略）
- `iovcc-supply` / `vcc-supply` — パネル電源を上で定義した固定レギュレータから供給
- `reset-gpios` — リセット信号のGPIO。BSP DTB から読み取った `gpio3 RK_PD3 (active-low)` を指定

### 5.3 Makefile への追加

`linux-6.19/arch/arm64/boot/dts/rockchip/Makefile` に 1 行追加して、ビルドシステムに新しい DTB を認識させます：

```makefile
dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3326-odroid-go2.dtb
dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3326-odroid-go2-v11.dtb
dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3326-r36ultra.dtb          # ← 追加
dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3326-odroid-go3.dtb
```

`dtb-$(CONFIG_ARCH_ROCKCHIP)` は「`CONFIG_ARCH_ROCKCHIP` が有効なときにビルドする DTB のリスト」です。

---

## 6. カーネルコンフィグとビルド

### 6.1 defconfig の生成

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
```

- `ARCH=arm64` — ARM 64bit 向けの defconfig を使う
- `CROSS_COMPILE=aarch64-linux-gnu-` — クロスコンパイラの接頭辞
- `defconfig` — `arch/arm64/configs/defconfig` をベースに `.config` を生成

### 6.2 追加オプションの有効化

defconfig には多くのドライバが含まれていますが、画面表示に必要な一部のドライバが有効になっていない（またはモジュールになっている）ため、`scripts/config` コマンドで追加します：

```bash
scripts/config --enable CONFIG_ARCH_ROCKCHIP
scripts/config --enable CONFIG_DRM_ROCKCHIP
scripts/config --enable CONFIG_DRM_PANEL_SITRONIX_ST7703
scripts/config --enable CONFIG_ROCKCHIP_DW_MIPI_DSI
scripts/config --enable CONFIG_PWM_ROCKCHIP
scripts/config --enable CONFIG_MFD_RK808
scripts/config --enable CONFIG_REGULATOR_RK808
scripts/config --enable CONFIG_MMC_DW_ROCKCHIP
scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE_ROTATION
scripts/config --enable CONFIG_BACKLIGHT_CLASS_DEVICE
```

> **追加（2026-09-22）：** 上記に加えて `CONFIG_PHY_ROCKCHIP_INNO_DSIDPHY=y`（DSI の物理層。`=m` のままでは画面が出ない）、`CONFIG_BACKLIGHT_PWM=y`、デバッグ用に `CONFIG_DYNAMIC_DEBUG=y` を有効化しました。さらにパネルドライバへの追記（§10.6）が必要です。

各オプションの意味：

| オプション | 何のドライバか | なぜ必要か |
|---|---|---|
| `CONFIG_ARCH_ROCKCHIP` | Rockchip SoC プラットフォームサポート | RK3326 を認識するため |
| `CONFIG_DRM_ROCKCHIP` | VOP (Video Output Processor) | RK3326 のディスプレイ出力ハードウェアを制御 |
| `CONFIG_DRM_PANEL_SITRONIX_ST7703` | ST7703 パネルドライバ | R36Ultra のパネルを駆動 |
| `CONFIG_ROCKCHIP_DW_MIPI_DSI` | Synopsys DesignWare MIPI DSI コントローラ | SoC とパネルを繋ぐバスのドライバ |
| `CONFIG_PWM_ROCKCHIP` | Rockchip PWM コントローラ | バックライトの明るさ制御 |
| `CONFIG_MFD_RK808` | RK8xx PMIC フレームワーク | RK817 PMIC の親ドライバ（複数機能を束ねる） |
| `CONFIG_REGULATOR_RK808` | RK8xx 電圧レギュレータ | 各電源レールの電圧制御 |
| `CONFIG_MMC_DW_ROCKCHIP` | Synopsys DesignWare MMC + Rockchip 拡張 | SD カードの読み書き |
| `CONFIG_FRAMEBUFFER_CONSOLE` | フレームバッファコンソール | DRM の画面出力上にテキストコンソールを表示 |
| `CONFIG_FRAMEBUFFER_CONSOLE_ROTATION` | fbcon 回転サポート | パネルの物理取り付け向きに合わせた回転 |
| `CONFIG_BACKLIGHT_CLASS_DEVICE` | バックライトクラスデバイス | バックライト制御の基盤 |

**画面表示に関わるドライバの関係図：**

```
ユーザーがキーボードを打つ
  ↓
フレームバッファコンソール (CONFIG_FRAMEBUFFER_CONSOLE)
  テキストを画面に描画 ← 回転処理 (CONFIG_FRAMEBUFFER_CONSOLE_ROTATION)
  ↓
DRM/KMS フレームワーク (CONFIG_DRM_ROCKCHIP)
  フレームバッファの内容を VOP (Video Output Processor) に送る
  ↓
MIPI DSI コントローラ (CONFIG_ROCKCHIP_DW_MIPI_DSI)
  画像データをシリアル信号に変換してパネルに送る
  ↓
ST7703 パネルドライバ (CONFIG_DRM_PANEL_SITRONIX_ST7703)
  パネルの初期化シーケンスの送信、電源制御
  ↓
物理的なパネル → ユーザーの目に映る
```

### 6.3 ビルドの実行

```bash
# カーネルイメージのビルド
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image
#                                                  ^^^^^^^^^
#                                                  並列ビルド。
#                                                  $(nproc) = CPUコア数を自動取得。
#                                                  コア数分の並列コンパイルを行い高速化。

# DTB のビルド（R36Ultra のみ）
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- rockchip/rk3326-r36ultra.dtb
#                                                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
#                                                 全DTBではなくR36Ultraのみをビルド。
#                                                 全DTBをビルドすると他アーキテクチャのDTBも
#                                                 含まれ、関係ない問題に巻き込まれる。
```

**出力物:**

| ファイル | サイズ | 説明 |
|----------|--------|------|
| `arch/arm64/boot/Image` | 49MB | カーネルイメージ（非圧縮） |
| `arch/arm64/boot/dts/rockchip/rk3326-r36ultra.dtb` | 47KB | デバイスツリーバイナリ |

**Image とは:** ARM64 用の非圧縮カーネルイメージです。PC の Linux では `vmlinuz`（圧縮済み）が一般的ですが、ARM の U-Boot は非圧縮の `Image` を直接ロードします。49MB と大きいですが、SD カードの容量的には問題ありません。

---

## 7. SD カードイメージの作成

### 7.1 なぜイメージファイル方式にしたか

今回の作業環境は WSL2 (Windows Subsystem for Linux) です。WSL では物理的な SD カードに直接アクセスすることが困難なため、以下の方式を採用しました：

1. WSL 内でイメージファイル (`.img`) を作成
2. イメージファイル内にパーティションを作り、カーネルや rootfs を配置
3. 完成したイメージファイルを Windows 側から Rufus や Etcher で SD カードに書き込む

### 7.2 イメージファイルの作成

```bash
# 8GB (7680MB) のゼロ埋めイメージファイルを作成
dd if=/dev/zero of=sdcard.img bs=1M count=7680 status=progress
#  ^^^^^^^^^^^^                ^^^^  ^^^^^^^^^^
#  入力: /dev/zero (無限のゼロ)  1MB単位  7680回 = 7.5GB
#                                                status=progress で進捗表示
```

**dd コマンドとは:** "data duplicator" の略で、低レベルなデータコピーを行うコマンドです。`if` (input file) から読んで `of` (output file) に書きます。`/dev/zero` は読むと無限にゼロを返す仮想デバイスで、これを使って指定サイズの空ファイルを作成できます。

### 7.3 パーティションテーブルの作成

```bash
sfdisk sdcard.img << 'EOF'
label: dos
unit: sectors

/dev/sdX1 : start=2048, size=524288, type=b, bootable
/dev/sdX2 : start=526336, type=83
EOF
```

- `label: dos` — MBR (Master Boot Record) パーティションテーブルを使う。U-Boot との互換性のため GPT ではなく MBR を選択。
- `start=2048` — パーティション 1 はセクタ 2048 から開始。先頭の 1MB (2048×512B) は U-Boot のヘッダ等のために空けておく慣習。
- `size=524288` — 524288 セクタ × 512B = 256MB
- `type=b` — パーティションタイプ `0x0B` = W95 FAT32
- `bootable` — ブートフラグを立てる
- `type=83` — パーティションタイプ `0x83` = Linux

結果：

```
sdcard.img (7.5GB)
┌────────────────────────────────────────────────────────────────┐
│ 1MB  │ パーティション1 (FAT32, 256MB) │ パーティション2 (ext4, 7.2GB) │
│ 予約 │ boot                           │ rootfs                        │
└────────────────────────────────────────────────────────────────┘
```

### 7.4 ループバックマウントとフォーマット

イメージファイルの中のパーティションに書き込むには、**ループバックデバイス**を使います。これはファイルをあたかもブロックデバイス（HDD や SD カード）のように扱うための Linux の仕組みです。

```bash
# イメージファイルをループバックデバイスにアタッチ (root 権限が必要)
sudo losetup --show -fP sdcard.img
#            ^^^^^^ ^^
#            デバイス名を表示  -f: 空きデバイスを自動選択
#                              -P: パーティションテーブルを読んで
#                                  /dev/loop0p1, /dev/loop0p2 を作成
# → /dev/loop0 と表示される

# パーティション1を FAT32 でフォーマット
sudo mkfs.fat -F 32 -n BOOT /dev/loop0p1
#             ^^^^^  ^^^^^^
#             FAT32   ボリュームラベル "BOOT"

# パーティション2を ext4 でフォーマット
sudo mkfs.ext4 -L rootfs /dev/loop0p2
#              ^^^^^^^^
#              ボリュームラベル "rootfs"

# マウント (普通のディレクトリとしてアクセスできるようになる)
sudo mkdir -p /mnt/sdboot /mnt/sdroot
sudo mount /dev/loop0p1 /mnt/sdboot
sudo mount /dev/loop0p2 /mnt/sdroot
```

### 7.5 ブートパーティションの構成

```bash
# カーネルイメージをコピー
sudo cp linux-6.19/arch/arm64/boot/Image /mnt/sdboot/

# デバイスツリーをコピー
sudo cp linux-6.19/arch/arm64/boot/dts/rockchip/rk3326-r36ultra.dtb /mnt/sdboot/

# extlinux ディレクトリを作成
sudo mkdir -p /mnt/sdboot/extlinux
```

**extlinux.conf を作成：**

```bash
sudo tee /mnt/sdboot/extlinux/extlinux.conf << 'EOF'
LABEL Arch Linux
  LINUX /Image
  FDT /rk3326-r36ultra.dtb
  APPEND root=/dev/mmcblk1p2 rootfstype=ext4 rw rootwait console=ttyS2,115200n8 console=tty0 fbcon=rotate:3 loglevel=7
EOF
```

各行・各パラメータの意味：

| パラメータ | 意味 |
|------------|------|
| `LABEL Arch Linux` | ブートエントリの名前（U-Boot のメニューに表示される） |
| `LINUX /Image` | カーネルイメージのパス（FAT32 パーティション内） |
| `FDT /rk3326-r36ultra.dtb` | デバイスツリーのパス。FDT = Flattened Device Tree |
| `APPEND ...` | カーネルに渡すコマンドライン引数（以下で詳細解説） |

`APPEND` 行のパラメータ：

| パラメータ | 意味 | なぜこの値か |
|------------|------|-------------|
| `root=/dev/mmcblk1p2` | rootfs のデバイス | **誤り。** BSP カーネルでは SD が `mmcblk1` だが、mainline の DTS は eMMC を無効にしているため SD は **`mmcblk0`**（§10.4）。最終版は `root=/dev/mmcblk0p2` |
| `rootfstype=ext4` | rootfs のファイルシステム | 明示的に指定して自動検出の時間を節約 |
| `rw` | rootfs を読み書き可能でマウント | 初回起動時に設定変更等を行うため |
| `rootwait` | root デバイスが見つかるまで待つ | SD カードコントローラの初期化に時間がかかることがある。これがないと rootfs が見つからず kernel panic になる |
| `console=ttyS2,115200n8` | UART2 にシリアルコンソールを出力 | **誤り。** 実機のデバッグ UART は UART5 で速度は 1,500,000 baud（§10.3）。最終版は `console=ttyS0,1500000n8` |
| `console=tty0` | 画面にもコンソールを出力 | 複数の `console=` を指定した場合、最後のものがデフォルト出力先になる |
| `fbcon=rotate:3` | フレームバッファコンソールを 270 度回転 | パネルの物理的な取り付け向きの補正。ArkOS も同じ設定 (rotate:3 = 270度) |
| `loglevel=7` | カーネルログを最大限表示 | デバッグ用。初回起動では何が起きているか見えることが重要 |

### 7.6 rootfs の展開

```bash
# Arch Linux ARM AArch64 tarball を rootfs パーティションに展開
sudo tar -xpzf ArchLinuxARM-aarch64-latest.tar.gz -C /mnt/sdroot
#        ^^^^
#        -x: 展開
#        -p: パーミッション（ファイルの所有者・権限）を保持 ★重要
#        -z: gzip 圧縮を展開
#        -f: ファイル名を指定
```

**`-p` フラグが重要な理由：** Linux のファイルには所有者やパーミッション（rwx）が設定されています。`-p` を付けないと全てのファイルが展開したユーザーの所有になり、rootfs として正しく動作しません。特に `/bin/su` のような setuid ファイルは正しいパーミッションが必須です。

**なぜ Arch Linux ARM か：** 軽量でミニマルな rootfs。起動後に `pacman`（パッケージマネージャ）でソフトウェアを追加できます。

### 7.7 rootfs の設定

#### fstab の作成

```bash
sudo mkdir -p /mnt/sdroot/boot/firmware
sudo tee /mnt/sdroot/etc/fstab << 'EOF'
LABEL=BOOT      /boot/firmware  vfat    defaults        0 0
LABEL=rootfs    /               ext4    defaults        0 1
EOF
```

デバイス名ではなくラベルで書く（§10.4）。BOOT パーティションは `/boot` ではなく **`/boot/firmware`** に載せる。rootfs には Arch Linux ARM 標準のカーネルパッケージ `linux-aarch64` が入っていて、pacman の記録では `/boot/Image` はそのパッケージのファイルになっている。`/boot` に BOOT を載せると、`pacman -Syu` が自作の `Image` を標準カーネルで上書きし、mkinitcpio が initramfs を書いて FAT を満杯にする（§10.11）。`/boot/firmware` なら、それらは rootfs 側の `/boot` ディレクトリに書かれるだけで、U-Boot が読む FAT には触れない。

**fstab とは:** File Systems Table の略。Linux が起動時に「どのデバイスをどのディレクトリにどのファイルシステムでマウントするか」を記述するファイルです。

- 1 列目: デバイス名
- 2 列目: マウントポイント
- 3 列目: ファイルシステムの種類
- 4 列目: マウントオプション
- 5 列目: dump の頻度（0=しない）
- 6 列目: fsck の順番（0=チェックしない、1=最初にチェック、2=その後）

#### root パスワードの設定

通常は `chroot`（別のルートディレクトリでコマンドを実行する仕組み）を使って `passwd` コマンドでパスワードを設定しますが、WSL (x86) 上で AArch64 のバイナリは実行できません（`Exec format error` になる）。

代わりに `/etc/shadow` ファイル（パスワードのハッシュが格納されているファイル）を直接編集します：

```bash
# パスワード "root" の SHA-512 ハッシュを生成
HASH=$(openssl passwd -6 root)
#                     ^^
#                     -6 = SHA-512 アルゴリズム

# /etc/shadow の root 行を更新
sudo sed -i "s|^root:[^:]*:|root:${HASH}:|" /mnt/sdroot/etc/shadow
```

#### ホスト名の設定

配布物の `/etc/hostname` は `alarm` です。ログインプロンプト、シェルのプロンプト、screenfetch の見出しに出る名前を機種名にするため、ここで書き換えます（2026-09-22 追加）。

```bash
echo R36Ultra | sudo tee /mnt/sdroot/etc/hostname
```

**`/etc/hostname` とは:** 起動時に systemd が読むホスト名の設定ファイルです。配布物のどのパッケージにも属さないので、パッケージを更新しても書き換わりません。大文字も使えます（systemd 259 のソースで確認）。起動後に変える場合は、本体で `hostnamectl set-hostname R36Ultra` を実行しても同じファイルが書き換わります。

#### WiFi 用ファイルの展開

```bash
sudo tar -xpf wifi_stage/wifi-rootfs.tar -C /mnt/sdroot --no-overwrite-dir
```

`wifi-rootfs.tar` は `make_wifi_stage.sh` が作る（§10.13）。WiFi に必要な rootfs 側のものがすべて入っている：カーネルモジュール 5 個と depmod の結果、ファームウェア、`wpa_supplicant`・`iw`・`wireless-regdb` のファイル、`wpa_supplicant@wlan0` と `dhcpcd@wlan0` の自動起動、接続先が空の `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`。カーネル（`Image`）を作り直したら、この tar も作り直して展開し直す（モジュールはカーネルのリリース名ごとのディレクトリに入る）。**既に使っているカードに展開し直すときは `--exclude='./etc/wpa_supplicant'` を付ける。** 付けないと、接続先を追記した設定ファイルが tar の空の設定で上書きされ、起動しても繋がらなくなる（2026-09-23 に実際に起きた）。2026-09-24 から、この tar は `/etc/conf.d/wireless-regdom` の国コードも `JP` にする（§10.13 の追記）。**カードに書いた後の同期は `sync -f /mnt/sdboot`・`sync -f /mnt/sdroot` を使い、引数なしの `sync` は使わない。** WSL では死んだ 9p マウント（Windows のドライブ。2026-09-25 は Google Drive の G:）があると全体 `sync` が D 状態で永久に止まり、`hung_task_timeout_secs=0` なので警告も出ない（2026-09-25 に実際に 9 時間止まった）。カード上の内容で照合したいときは umount して読み直す（umount でブロックデバイスのキャッシュは捨てられる）。

```bash
sudo tar -xpf wifi_stage/wifi-rootfs.tar -C /mnt/sdroot --no-overwrite-dir --exclude='./etc/wpa_supplicant'
```

接続先（SSID とパスワード）は、起動後に実機で追記する：

```bash
wpa_passphrase "SSID" "パスワード" >> /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
systemctl restart wpa_supplicant@wlan0
```

#### GUI 用ファイルの展開

```bash
sudo tar -xpf gui_stage/gui-rootfs.tar -C /mnt/sdroot --no-overwrite-dir
```

`gui-rootfs.tar` は `make_gui_stage.sh` が作る（§10.14）。sway・foot・フォント・libgpiod と、その依存パッケージ（計 81 個）をファイルとして展開し、720x720 向けの `foot.ini`、起動用の `start-sway`、スティックとカーソルの常駐プログラム `r36u-joyd`（自動起動のシンボリックリンク込み）を入れる。**glibc 2.43 も含む**：rootfs の tarball は 2.42 で、今のパッケージはそれでは動かない（§10.14）。約 542MB なので rootfs に 1.5GB 以上の空きが要る。`r36u_joyd.c` やパッケージを変えたら作り直して展開し直す。

### 7.8 アンマウントとイメージ完成

```bash
sudo umount /mnt/sdboot /mnt/sdroot
sudo losetup -d /dev/loop0
#            ^^
#            -d = デタッチ（ループバックデバイスを解放）
```

完成物: `sdcard.img` (7.5GB)

---

## 8. SD カードへの書き込みと起動

### 8.1 イメージの書き込み

WSL 内のファイルは Windows から `\\wsl$\Ubuntu\home\...` でアクセスできます。

1. Windows で **Rufus** または **Etcher** を起動
2. `sdcard.img` を選択
3. SD カードを選択
4. **DD モード**（ディスクイメージモード）で書き込み

> DD モードを選ぶ理由: イメージファイルにはパーティションテーブルが含まれており、ファイルの中身をそのまま SD カードに書き込む必要があるため。

### 8.2 起動

1. SD カードを R36Ultra に挿入
2. 電源 ON
3. 期待される起動シーケンス:

```
U-Boot SPL (BootROM が eMMC から読み込む)
  ↓
U-Boot (SD カードの extlinux.conf を検出)
  ↓
Image + DTB をメモリにロード
  ↓
Starting kernel ...
  ↓
カーネル起動ログ (loglevel=7 なので大量に表示)
  ↓
[  OK  ] Started Login Service.
  ↓
Arch Linux 6.19.0 r36ultra tty1

r36ultra login: _     ← ★目標達成
```

### 8.3 ログイン

- ユーザー名: `root`
- パスワード: `root`

---

## 9. 既知の課題と次のステップ

> **2026-09-22 更新：** 本章の課題のうち「パネル」「ログインプロンプト到達」は解決しました。経緯と最終構成は §10 を参照。以下は当初の記述です。

### パネルが映らない場合

RGB30 パネルの初期化シーケンスが R36Ultra のパネルに合わない可能性があります。

**解決策:** BSP DTB に記載されている R36Ultra 固有の初期化シーケンス（`panel-init-sequence` プロパティ、数百バイトの MIPI DCS コマンド列）を C コードに変換し、`drivers/gpu/drm/panel/panel-sitronix-st7703.c` に新しいパネル定義として追加します。

### WiFi が使えない

RK915 用のドライバは mainline にありません。有志の mainline 移植版を out-of-tree モジュールとしてビルドして使います（§10.13）。

### ジョイスティックが動かない

**解決済み（§10.14）。** 4 軸すべてが 1 本の SARADC（ch1）に多重化されていて、gpio2 の 2 本で切り替えるため、mainline の `adc-joystick`（1 軸 = 1 チャンネル前提）では表現できない。自作の常駐プログラム `r36u-joyd` が切り替えと読み出しを行い、uinput でゲームパッドとカーソルを作る。

### 音声が出ない

I2S + RK817 内蔵 codec の設定が必要です。ODROID-Go の DTSI にオーディオ設定が含まれているため、基本的には継承されるはずですが、未検証です。

---

## 付録 A: 作成・変更したファイル一覧

| ファイル | 操作 | サイズ |
|----------|------|--------|
| `linux-6.19/arch/arm64/boot/dts/rockchip/rk3326-r36ultra.dts` | 新規作成 | 41 行 |
| `linux-6.19/arch/arm64/boot/dts/rockchip/Makefile` | 1 行追加 | — |
| `linux-6.19/.config` | defconfig + scripts/config | — |
| `linux-6.19/arch/arm64/boot/Image` | ビルド成果物 | 49MB |
| `linux-6.19/arch/arm64/boot/dts/rockchip/rk3326-r36ultra.dtb` | ビルド成果物 | 47KB |
| `rk3326_arch/sdcard.img` | SDカードイメージ | 7.5GB |
| `linux-6.19/arch/arm64/boot/dts/rockchip/rk3326-r36ultra-nodisp.dts` | 新規作成（現在使う DTB。§10.12） | — |
| `linux-6.19/drivers/mmc/{core/quirks.h,core/sdio_cis.c,host/dw_mmc.c}`、`include/linux/mmc/card.h` | RK915 の card quirk（§10.13） | — |
| `rk915/` | WiFi ドライバ（git、ブランチ `main`。§10.13） | — |
| `make_wifi_stage.sh` → `wifi_stage/wifi-rootfs.tar` | rootfs に展開する WiFi 一式（§7.7、§10.13） | 54 エントリ |
| `pkgs/*.pkg.tar.xz` | tar に入れるユーザー空間の元パッケージ（署名付き） | — |
| `fetch_pkgs.py` | Arch Linux ARM のパッケージ収集（依存解決・SHA256 照合。§10.14） | — |
| `pkgs/gui/*.pkg.tar.xz` | GUI 用の元パッケージ 81 個（署名付き） | 104MB |
| `make_gui_stage.sh` → `gui_stage/gui-rootfs.tar` | rootfs に展開する GUI 一式（§7.7、§10.14） | 13,110 エントリ |
| `r36u_joyd.c` → `/usr/local/bin/r36u-joyd` | スティック（多重化された ADC）とカーソルの常駐プログラム（§10.14） | — |

**シンボリックリンク修正（GitHub tarball 問題で必要だったもの）：**

| ファイル | リンク先 |
|----------|----------|
| `arch/arm64/tools/syscall_64.tbl` | `../../../scripts/syscall.tbl` |
| `scripts/dtc/include-prefixes/dt-bindings` | `../../../include/dt-bindings` |
| `scripts/dtc/include-prefixes/arm64` | `../../../arch/arm64/boot/dts` |
| （他 10 エントリ） | （同様の `../../../arch/*/boot/dts` パターン） |
| `include/dt-bindings/input/linux-event-codes.h` | `../../uapi/linux/input-event-codes.h` |

## 付録 B: 用語集

| 用語 | 説明 |
|------|------|
| **SoC** | System on Chip。CPU、GPU、各種コントローラを 1 チップに統合したもの |
| **DTS/DTB/DTSI** | Device Tree Source / Blob / Source Include。ハードウェア構成をカーネルに伝えるデータ |
| **U-Boot** | ARM 組み込みで標準的なブートローダ。PC の GRUB に相当 |
| **BootROM** | SoC 内蔵の読み取り専用起動プログラム。U-Boot を読み込む |
| **GPIO** | General Purpose Input/Output。汎用入出力ピン |
| **PMIC** | Power Management IC。電源管理チップ。各部品への電圧供給を制御 |
| **MIPI DSI** | Mobile Industry Processor Interface - Display Serial Interface。ディスプレイ接続規格 |
| **PWM** | Pulse Width Modulation。パルス幅変調。バックライト明るさ制御に使用 |
| **DRM/KMS** | Direct Rendering Manager / Kernel Mode Setting。Linux のディスプレイ制御フレームワーク |
| **VOP** | Video Output Processor。Rockchip SoC のディスプレイ出力ハードウェア |
| **クロスコンパイル** | 自分の CPU と異なるアーキテクチャ向けにコンパイルすること |
| **defconfig** | アーキテクチャごとのデフォルトカーネル設定 |
| **extlinux** | U-Boot が理解するブート設定フォーマット |
| **rootfs** | ルートファイルシステム。カーネル起動後のユーザー空間ファイル一式 |
| **fbcon** | フレームバッファコンソール。画面上のテキスト表示 |
| **vDSO** | Virtual Dynamic Shared Object。高速システムコール用の共有ライブラリ |
| **SARADC** | Successive Approximation Register ADC。逐次比較型アナログ-デジタル変換器 |
| **BSP** | Board Support Package。メーカー提供のカーネル + ドライバ + 設定一式 |
| **initramfs** | 初期 RAM ファイルシステム。カーネルが rootfs をマウントする前の一時的環境 |
| **MBR** | Master Boot Record。パーティションテーブル形式の一つ（GPT の前身） |
| **ループバックデバイス** | ファイルをブロックデバイスとして扱う Linux の仕組み |


---

## 10. 実機での起動デバッグ記録（2026-09-21〜22）

第 8 章の手順で作った SD カードを実機に挿しても、画面には何も出ませんでした。ここから 2 日かけて原因を 1 つずつ特定し、**パネルとシリアルの両方にログインプロンプトが出る状態**に到達するまでの記録です。前半の章で「こうなるはず」と書いたことのうち、実機で覆ったものも訂正しています。

### 10.1 結論：最終的に動いた構成

| 要素 | 内容 |
|---|---|
| カーネル | 6.19.0、`Image` 52,775,424 B（§10.2 の修正と `CONFIG_DRM_SIMPLEDRM=y` を含む） |
| DTB | `rk3326-r36ultra-nodisp.dtb`（U-Boot の画面を引き継ぐ構成。§10.12） |
| `extlinux.conf` | §10.9（`extlinux.conf.v27`（2026-09-30 に実機の現物と一致を確認。v26 は `console=` の順が違うだけ、v28 は `log_buf_len=8M` を足した未投入版）） |
| シリアル | UART5、**1,500,000 baud**、`ttyS0` にログインプロンプト |
| ログイン | `root` / `root`（§7.7 で設定）。既定ユーザー `alarm` / `alarm` も存在 |
| 画面 | U-Boot の画面を simpledrm で引き継ぐ。5 回中 5 回表示、回転の指定なしで正しい向き（§10.12） |
| ホスト名 | `R36Ultra`（§7.7） |

### 10.2 tarball 問題 6：空のシステムコール表 —— すべての userspace が即死した根本原因

**症状：** カーネルは rootfs をマウントし `/sbin/init` を起動するが、init が直後に死んで `Kernel panic - Attempted to kill init! exitcode=0x00000005`。`init=/usr/bin/true` でも同じ。Ubuntu の静的 glibc で自前ビルドした診断用バイナリ（`diag_init`）も `exitcode=0x0b`（SIGSEGV）で即死。**動的リンクも静的リンクも、どんなプログラムも動かない**。

**手がかり：** `sysctl.debug.exception-trace=1` で落ちた瞬間のレジスタを表示させると、`__memcpy_generic` がアドレス `0x750` へ書こうとして落ちていた。glibc の初期化で TLS 領域を `brk` システムコールで確保する処理が、`brk` の戻り値がおかしいために 0 付近を指していた。**システムコールの結果が壊れている**疑い。

**原因：** `arch/arm64/include/generated/asm/syscall_table_64.h` が **0 バイト**だった。これはカーネル内部のシステムコール・ディスパッチ表（`arch/arm64/kernel/sys.c` の `sys_call_table[]`）を生成するヘッダで、§4.2 の問題 2 で symlink を修復する **7 分前**に、当時 36 バイトのテキストだった `syscall_64.tbl` から生成されていた。kbuild は依存ファイルの更新時刻で再生成を判断するため、symlink 修復後も「最新」とみなして再生成しなかった。§4.2 では userspace 向けの `unistd_64.h` だけを手で再生成し、カーネル側の表を見落としていた。**表が空 → 全システムコールが `-ENOSYS`** → glibc が致命的エラーで `brk #1000`（SIGTRAP）を実行、静的バイナリは TLS 確保に失敗して SIGSEGV。

**修正：**
```bash
cd linux-6.19
find include/generated arch/arm64/include/generated -type f -size 0 -print -delete
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j16 Image
grep -c __SYSCALL arch/arm64/include/generated/asm/syscall_table_64.h   # → 471
```

**教訓：** symlink を修復したら、`include/generated` 配下の **0 バイトのファイル**を必ず探すこと。もっと確実なのは、`.config` を退避したうえで `make mrproper` して生成物を全部作り直すこと。

### 10.3 デバッグ UART の正体と、シリアルが「死ぬ」ように見えた 3 つの理由

**事実（U-Boot のログ `PreSerial: 5, raw, 0xff178000`、BSP の `fiq-debugger { rockchip,serial-id = <5>; rockchip,baudrate = <1500000>; }`、px30.dtsi の `uart5: serial@ff178000` で確認）：**
- デバッグ UART は **UART5**。§7.5 で書いた `ttyS2` は誤り。
- 速度は **1,500,000 baud**（Rockchip PX30/RK3326 系の標準）。§7.5 の 115200 は誤り。TeraTerm も 1.5M に設定されていた。
- mainline では、`console=` を指定しないと `ttyS0` として登録される（8250 の登録ポート数の上限 4 のため、別名 `serial5` は使えない）。

**理由 1：`console=ttyS5,115200n8` / `console=ttyS0,115200n8` で 0.75 秒に出力が消える** —— 8250 ドライバが本当に 115200 に設定し直すので、1.5M の受信側とは 13 倍ずれる。化け文字にもならず「きれいに止まったように見える」。**正しくは `console=ttyS0,1500000n8`。**

**理由 2：earlycon は `115200n8` 指定でも読めていた** —— 8250 の earlycon は基準クロックを 1.8432MHz と仮定して分周比を計算するため、`115200` → 分周比 1 → 実クロック 24MHz のこの UART では **1.5M で動く**。偶然一致していただけ。速度指定を外して `earlycon=uart8250,mmio32,0xff178000` とすれば U-Boot の設定を継承する（未検証）。

**理由 3：`console=` 無しだと 1.3 秒付近で earlycon 出力が止まる** —— 8250 ドライバが UART5 を probe するが誰も所有しない状態になると、以降の出力が止まる（機構は未特定。BSP は 8250 ノードを無効にして専用ドライバで占有している）。`console=ttyS0,1500000n8` で所有させれば起きない。この現象を長時間「カーネルの停止」と誤診していた。カーネルは動いており、ext4 のスーパーブロックに実機の時計（1970 年）でのマウント記録が残っていたことで判明した。

### 10.4 SD カードは `mmcblk0`、fstab はラベルで

mainline の `rk3326-odroid-go.dtsi` は eMMC を有効にしていないため、SD が唯一の MMC = `mmcblk0`。`root=/dev/mmcblk0p2` に変更。rootfs の `/etc/fstab` はデバイス名でなくラベルで書き、BOOT は `/boot/firmware` に載せる（理由は §7.7）：
```
LABEL=BOOT      /boot/firmware  vfat    defaults        0 0
LABEL=rootfs    /               ext4    defaults        0 1
```

### 10.5 電源と I/O 電圧 —— ODROID-Go の設定は R36Ultra と違う

`rk3326-odroid-go.dtsi` を継承したことで、**RK817 の出力割り当てと I/O 電圧宣言が別基板のものになっていた**。BSP の DTS と機械的に突き合わせて修正（詳細は `DIFF_REPORT.md` §2.5、§2.6）：

| 項目 | ODROID-Go（継承していた値） | R36Ultra（BSP） |
|---|---|---|
| DCDC_REG4 | vcc_3v3 = 3.3V | **vcc_3v0 = 3.0V** |
| LDO_REG4 | vcc3v3_pmu = 3.3V | **vcc3v0_pmu = 3.0V** |
| LDO_REG7 / 8 | vcc_bl 3.3V / vcc_lcd 2.8V | vcc2v8_dvp 1.8–3.3V / vcc1v8_dvp 3.3V（always-on） |
| io-domain vccio3 | 3.3V 宣言 | **1.8V**（`vcc1v8_soc`） |
| io-domain vccio1 / vccio6 | vcc_3v3 / vcc_3v3 | vcc2v8_dvp / **未設定** |

io-domain は「この GPIO バンクは何ボルトか」を SoC に宣言する設定で、実際の電源と食い違うとそのバンクの信号が壊れる。`vccio3` の修正直後に初めてパネルに表示が出た（ただし不安定。§10.6）。

### 10.6 パネル —— RGB30 の初期化シーケンス流用では映らない

§3.2 の方針（RGB30 の設定を流用）は、**BSP の `panel-init-sequence` を復号して比較**した結果、24 コマンド中 15 が異なり（電源 B1/B8/BC、VCOM B6、GIP E9/EA、ガンマ E0、追加の C1/C6/C7/C8/EF）、表示モードも 45MHz/1080×764 vs 36.57MHz/814×749 で別物だった。表示は「3 回に 1 回出る」不安定さで、これが原因。

**対処：** `drivers/gpu/drm/panel/panel-sitronix-st7703.c` に **R36Ultra 用エントリ**（`r36ultra_init_sequence`、`r36ultra_mode`、`r36ultra_desc`、compatible `"rgameconsole,r36ultra-panel"`）を追加。初期化シーケンスは BSP の 370 バイトからスクリプトで機械生成した（手打ちの転記ミスを避けるため）。DTS のパネル `compatible` をこれに変更。BSP のディレイ（リセット後 120ms、SLPOUT 後 250ms）も反映。

BSP と mainline のバックライトも比較し、BSP と同じ 256 段・既定 200 に揃えた（それまでは既定値が無く、起動 2 秒でバックライトが薄くなっていた）。

### 10.7 ODROID-Go 固有の周辺機器を無効化

継承した DTSI が有効にしていた UART2 / PWM3 / SFC（SPI フラッシュ）/ gpio-keys / leds は R36Ultra には存在せず、そのピンは R36Ultra では eMMC 配線・充電 LED・ゲームパッドのボタンに使われている（`DIFF_REPORT.md` §2.3、§2.13、§2.14）。すべて `status = "disabled"`。SD の `max-frequency` も BSP と同じ 100MHz に。

### 10.8 最終的な DTS の要点

`rk3326-r36ultra.dts` は `rk3326-odroid-go.dtsi` を継承し、以下を上書きしている（全文はファイルを参照。各項目の根拠は BSP との差分）：

1. パネル：`compatible = "rgameconsole,r36ultra-panel"`、リセット gpio3 D3、電源 `vcc18_lcd_n`（gpio3 A3、active-high）
2. RK817 レギュレータ：§10.5 の表の値。LDO_REG9（1.5V）を追記
3. io-domain：`vccio1 = vcc2v8_dvp`、`vccio3 = vcc_1v8`、`vccio6` 削除
4. uart5：有効。ピンは `uart5_xfer` のみ（`uart5_cts` は gpio3 A3 = パネル電源と衝突するため除外）
5. 無効化：uart2、pwm3、sfc、gpio-keys（`builtin_gamepad`）、gpio-leds、led-controller
6. sdmmc：`max-frequency = <100000000>`
7. backlight：256 段、既定 200

### 10.9 最終的な extlinux.conf

2026-09-22 に `extlinux.conf.v23` から差し替えた。v23 は Linux でパネルを初期化し直す方式で、表示は 5 回に 1 回程度しか成功しなかった。

```
LABEL Arch Linux
  LINUX /Image
  FDT /rk3326-r36ultra-nodisp.dtb
  APPEND root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait earlycon=uart8250,mmio32,0xff178000,115200n8 keep_bootcon clk_ignore_unused pd_ignore_unused regulator_ignore_unused console=tty0 console=ttyS0,1500000n8 loglevel=7
```

- `FDT /rk3326-r36ultra-nodisp.dtb`：表示系ドライバを動かさず、U-Boot の画面を引き継ぐ DTB（§10.12）。名前は切り分け用に作った時の名残
- `console=tty0 console=ttyS0,1500000n8`：両方に出力。最後の指定が `/dev/console` になるので systemd のメッセージはシリアル側。systemd はこれを見て `serial-getty@ttyS0` を自動起動する（＝シリアルのログインプロンプト）
- `earlycon=...115200n8`：§10.3 理由 2 の通り偶然 1.5M で動いている。速度指定を外すのが本来の形（未検証）
- `clk_ignore_unused pd_ignore_unused regulator_ignore_unused`：使っていないクロック・電源ドメイン・レギュレータを切らない。引き継ぎの前提を確かめるときに全体へ効かせたまま残している。§10.12 の simple-framebuffer ノードが必要な資源を保持しているので不要な可能性が高いが、外しての検証は未実施
- `fbcon=rotate:3` は外した。引き継ぎ方式では回転の指定なしで正しい向きになった。向きに関わる設定の差はこの指定だけなので、以前の左 90° 回転はこれが原因だったと考えられる

### 10.10 教訓

1. **動作している FW（純正・ArkOS）の DTB と機械的に全項目を比較する。** 拾い読みでは 6 出力のレギュレータ違い、io-domain、3 つの無関係な周辺機器、24 コマンドの初期化シーケンスの差を見落とした。`DIFF_REPORT.md` はその全列挙。
2. **観測手段（シリアル）が壊れている可能性を最初に疑う。** 速度の前提（115200）を確認せずに 10 回以上起動を無駄にした。
3. **一度に 1 つだけ変える。基準点（動いた構成）が再現するかを先に確かめる。**
4. **「ビルドが通った」「書いたつもり」を「反映された」と言わない。** DTB は `dtc` で読み戻す、カーネルは `System.map` や生成ヘッダの中身を見る。空の生成ファイル（§10.2）はこれで見つかった。
5. **ログは起動ごとに別ファイルで保存し、採取時間を記録する。**「出なかった」と「採取していなかった」の区別が付かないと判断を誤る。
6. **動いている FW が「何をしていないか」も実物で確かめる。** 純正と ArkOS は起動時にパネルを初期化し直していなかった。手本の無い再初期化の手順を、U-Boot とのレジスタ合わせで直そうとして多くの起動を費やした（§10.12）。

### 10.11 残課題

- `clk_ignore_unused pd_ignore_unused regulator_ignore_unused` の要否（§10.9）
- `rk3326-r36ultra-nodisp.dts` を正式な名前にする
- 再初期化方式の調査で入れた変更（§10.12 の最後）の扱い。使うなら効果を検証し、使わないなら戻す。ソースの注記の未検証の断定も直す
- 充電器・電池ドライバ：`CONFIG_CHARGER_RK817=m` だがモジュールを入れていないので読み込まれていない。DT の電池ノードは ODROID-Go 用の流用なので、そのまま有効にしないこと。純正の値は、充電 500mA、4.2V、容量 2832mAh、入力電流 500mA。**2026-09-26 追記：** その後 `=y` にして `rk817-battery` は出ているが、**電圧・電流が更新されない**。`voltage_avg` = 3556180µV、`current_avg` = -523568µA が 5 秒おきの 3 回とも、2 日前（9/24）の採取とも 1µV/1µA まで同値。USB 給電中（`rk817-charger` の `online` = 1）でも `status` は Discharging。`charge_now` だけは 302892→290852µAh と動く（クーロンカウンタは読めている）。電圧・電流の ADC（ガスゲージ）が動いていない疑い。BSP の rk817 充電ドライバの初期化（GG_CON / ADC 有効化、`rockchip,resistor-sense-micro-ohms` = ODROID-Go 流用の 10000）と比較して切り分ける。表示される残量（10%）は信用できない → **2026-09-29 に解決**：RTC ドライバ（`RTC_DRV_RK808=y`）が RTC を走らせたら電圧・電流が更新されるようになった（§10.15）
- USB キーボードを起動後に挿すと再起動した。電池コネクタの挿し直し（接触不良の解消）の後で再確認していない
- earlycon の速度指定を外す
- BSP との残差分：`regulator-initial-mode`、LDO_REG1 / OTG_SWITCH、`rockchip-suspend`、DMC、入力デバイス（gamepad / adc-joystick）の R36Ultra 向け定義。USB は純正がホスト専用・VBUS スイッチ（GPIO3 A4）を管理しているのに対し、我々は OTG でスイッチを管理していない
- WiFi（RK915）：接続と ping まで確認（§10.13）。未確認は長時間の通信、`wifi-rootfs.tar` に入れた自動起動での再起動後の接続、サスペンド
- rootfs に Arch Linux ARM 標準カーネル `linux-aarch64`（6.18.3）と mkinitcpio が残っている。使っていないが、消すには pacman を動かす必要がある。`/boot/Image` を上書きされる問題は fstab で BOOT を `/boot/firmware` に載せて避けている（§7.7）。いま使っているカードは fstab が古い `/boot` のままなので、次にホストで rootfs を触るときに直し、BOOT に書かれた `initramfs-linux*.img` を消す → **2026-09-29 に `/boot/firmware` へ載せ替え済み**（§10.15。BOOT に initramfs は残っていなかった）
- 音声（I2S1 + RK817 codec）未検証
- pmic ノードに `system-power-controller` が無い（純正は `rockchip,system-power-controller` あり）。無いとカーネルは RK817 に電源断を頼めず、shutdown 後に長押しが要る。また `shutdown -h now` した回でも次の起動で journal が「uncleanly shut down」になっており、journal は WiFi 停止直後で途切れている。シリアルで shutdown を採取して切り分ける（2026-09-24、ssh での調査）→ **2026-09-29 に DT に追加**（§10.15）。電源が切れるかの試験と shutdown の採取は未実施
- BOOT の FAT に dirty フラグが立ったまま。Linux の vfat は「マウント時に既に dirty なら umount でも消さない」ので、過去 1 回の抜き差しか電源断で以後ずっと警告が出る。ホストで `fsck.fat -a` を 1 回 → **2026-09-29 に実施、警告は消えた**（§10.15）
- 熱管理・RTC・GPU のドライバが `=m` で入っていない（`ROCKCHIP_THERMAL`、`RTC_DRV_RK808`、`DRM_PANFROST`）。ハードと DT は揃っていて、実機に `ff280000.tsadc`・`rk808-rtc.3.auto`・`ff400000.gpu` が出ている。GPU の OPP 電圧（0.95〜1.125V）と `vdd_logic` の範囲は純正と同じ。mesa 26.2 の `panfrost_dri.so`・EGL・GBM は gui tar に入っている（2026-09-24）→ **2026-09-29 に thermal と RTC は `=y` にして実機で確認**（§10.15）。GPU（`DRM_PANFROST=y`）はビルド #19 で対応中
- sshd の `PermitRootLogin yes`（`/etc/ssh/sshd_config.d/10-r36ultra.conf`）は 2026-09-24 に実機で手で置いた。stage に入っていないので新しいカードでは再現しない → `make_wifi_stage.sh` に有効化リンクと drop-in を足すパッチを 2026-09-29 に作成（未適用、作業者が当てる）

### 10.12 画面表示の最終方式：U-Boot の画面を引き継ぐ（2026-09-22）

**経緯：** Linux でパネルを初期化し直す方式（§10.6、§10.8）は、表示の成功が 5 回に 1 回程度から改善しなかった。PHY と DSI ホストのレジスタを U-Boot と揃え、初期化の順序を BSP に合わせても 0/5 のままだった。

**純正と ArkOS の実物で確認した事実：**

- どちらのカーネルも Rockchip BSP の 5.10.160（バージョン文字列）。パネルは panel-simple と DT の `panel-init-sequence` で駆動し、ST7703 専用ドライバは無効（カーネルに埋め込まれた設定）
- DT の `display-subsystem/route/route-dsi` が有効で、`drm-logo` の予約メモリがある。位置は起動時に U-Boot が書き込む
- 引き継ぎ時の `panel_simple_loader_protect()` は、パネルを「初期化済み」として扱うだけで初期化列を送らない（BSP 5.10 の公開ソース。両 FW のカーネルに同名の関数があることを、シンボル表を復元して確認）
- つまり純正と ArkOS は、起動時にパネルを初期化し直さない。確実に動いている初期化は U-Boot のものだけ

**実装（`rk3326-r36ultra-nodisp.dts`）：**

- VOP・DSI・DSI PHY・VOP の IOMMU・パネルのノードを無効化し、Linux が表示系に触れないようにする
- `vcc18_lcd_n` に `regulator-boot-on`（純正と同じ）。無いと固定レギュレータが probe 時に GPIO3 A3 を Low にし、パネル電源を切る
- U-Boot の画面メモリ `0x3e07c000` を `reserved-memory` で `no-map` 予約。720×720、RGB888、1 行 2160 B で、大きさは `0x17c000`（VOP の WIN1 レジスタのダンプで確認）。この領域は、カーネルが CMA に使う範囲（`0x3cc00000` から 32MB）と重なっていた
- `/chosen` に `simple-framebuffer` ノードを置く。`memory-region` で上の予約領域を指し、VOP・DSI・PHY のクロック 6 本、電源ドメイン `PX30_PD_VO`、`panel-supply` を保持させる
- カーネル設定 `CONFIG_DRM_SIMPLEDRM=y`

**結果：** 5 回中 5 回表示した。画面の向きは回転の指定なしで正しい。

**画面メモリの位置：** U-Boot はロゴを毎回 `0x3df00000` に読み込み（手元の全起動のログで一致）、画面メモリはその直後に作られる。予約は固定アドレスなので、U-Boot やロゴ画像を変えた場合は位置を確かめ直すこと（VOP の `0xff4600a0` を読む）。

**再初期化方式の調査で入れた変更（現構成では動かない）：** 以下は表示用 DTB（`rk3326-r36ultra.dtb`）を使ったときだけ動く。どれも表示の安定化の効果は確認できておらず、ソースの注記には未検証の断定が含まれる。

- `phy-rockchip-inno-dsidphy.c`：電源 ON 時の PHY リセット、タイミングの余裕値（どちらも BSP のカーネルには無い）
- `dw-mipi-dsi-rockchip.c`：DT の `rockchip,lane-mbps` による速度固定、DSI ホストの遷移時間の固定値
- `dw-mipi-dsi.c`：PHY の電源 ON をロック待ちの前へ移し、待ちの失敗をエラー出力にする（Rockchip BSP のコミット c1901a57781a と同じ内容。両 FW のカーネルの機械語もこの順序）
- `panel-sitronix-st7703.c`：R36Ultra の初期化列を prepare で送る（BSP の panel-simple と同じ順序）

### 10.13 WiFi（RK915）：mainline 移植版ドライバで有効化（2026-09-22、接続と ping を確認）

**チップ：** RK915。純正 DTS の `wireless-wlan` に `wifi_chip_type = "rk915"` とあり、WiFi が動く ArkOS の rootfs にある SDIO WiFi ドライバは `rockchip_wlan/rk915/rk915.ko` だけ。純正 DTS の `seekwave,sv6160` ノードは無効で、使われていない。

**ドライバ：** `rk915/`（git、ブランチ `main`）を out-of-tree モジュールとしてビルドする。中身は次の 3 層。

| 層 | 出所 |
|---|---|
| 移植版本体 | sunshineinabox/rk915 @ `86f0d0e`（stolen/rk915 PR #2 の先頭。7.1 向け） |
| 実機で見つかった不具合の修正 4 本 | ROCKNIX/distribution PR #3252（Gusgu H7 で確認済み。LMAC を眠らせない、エラー回復の排他など） |
| 6.19 向け | 7.x の `kzalloc_obj()` / `kmalloc_obj()` を `kzalloc()` / `kmalloc()` に置換（5 か所） |

ファームウェア `rockchip/rk915_fw.bin`・`rockchip/rk915_patch.bin` は `request_firmware()` で読まれる。ArkOS の `/lib/firmware` のものとバイト一致。

**カーネルの変更：** RK915 は SDIO の規格に沿わない点が 3 つあり、MMC の card quirk として `rockchip,rk915` の compatible に紐付ける。7.1 用パッチ（`rk915/docs/mainline-linux-7.1-rk915-quirks.patch`）を 6.19 の dw_mmc（slot 構造）に合わせて移植した。他のカードの挙動は変わらない。

| quirk | 内容 | 変更箇所 |
|---|---|---|
| `MMC_QUIRK_BROKEN_SDIO_FUNCE` | 短い CISTPL_FUNCE を SDIO 1.0 として受け入れる | `sdio_cis.c` |
| `MMC_QUIRK_SDIO_CONT_CLOCK` | アイドル時もカードクロックを止めない | `dw_mmc.c` の `dw_mci_setup_bus()`、`dw_mci_prepare_sdio_irq()` |
| `MMC_QUIRK_SDIO_CMD52_WAIT_DATA` | DAT 線がビジーの間は CMD52 を待たせる | `dw_mmc.c` の `dw_mci_prepare_command()` |

ビット番号は 7.1 と同じ 21〜23（`include/linux/mmc/card.h`）。紐付けは `drivers/mmc/core/quirks.h` の `sdio_card_init_methods`。

**DT（`rk3326-r36ultra.dts`。nodisp 版も継承）：**

| 項目 | 純正 BSP | mainline |
|---|---|---|
| 電源 | rfkill-wlan が `WIFI,poweren_gpio` = GPIO0 A2（High で ON）を駆動 | `mmc-pwrseq-simple` の `reset-gpios` = GPIO0 A2 `GPIO_ACTIVE_LOW` |
| host-wake 割り込み | `WIFI,host_wake_irq` = GPIO0 A1。ドライバは `rockchip_wifi_get_oob_irq()` 経由で取得し、立ち上がりエッジ | `wifi@1` の `interrupts` = GPIO0 A1 `IRQ_TYPE_LEVEL_HIGH`、プルダウン |
| SDIO ホスト | `dwmmc@ff380000`、4 bit、50MHz | `&sdio`、4 bit、50MHz、`non-removable`、`cap-sdio-irq`、`keep-power-in-suspend` |
| MAC アドレス | DT に記述なし（BSP ドライバがどう決めるかは未調査） | `wifi@1` の `local-mac-address` = `<MAC>`（先頭 02 = 局所管理、残り 5 バイトは U-Boot が報告する SoC シリアルの末尾）。無いとドライバが起動ごとに乱数で決め、DHCP のリースが毎回変わる（2026-09-24 追記）。2026-09-30 に DT の値をやめ、rk915 の `macaddr` パラメータに machine-id から作った値を渡す方式にした（配布イメージの全機体が同じ MAC になるため） |

host-wake のピンは取り違えると受信できない。ドライバは受信をこの割り込みで駆動し、チップは DAT1 で割り込みを出さない（`rk915/src/sdio.c` の注記）。移植版の DT 例は GPIO0 A5 だが、これは Gusgu H7 の配線。トリガは移植版が実機で使った LEVEL_HIGH にした。受信できない場合の次の候補は、BSP と同じ立ち上がりエッジ。

SD カードは `aliases` の `mmc0 = &sdmmc` で番号が固定されているので、SDIO ホストが増えても `mmcblk0` のまま。

**`CONFIG_RESET_GPIO=y` が必要：** 6.19 の `pwrseq_simple` は `reset-gpios` が 1 本だけのとき、GPIO を直接使わず reset controller として取得する（`drivers/mmc/core/pwrseq_simple.c` の probe）。reset core は `CONFIG_RESET_GPIO` が有効なら reset-gpio デバイスを作り、そのドライバが登録されるまで `-EPROBE_DEFER` を返す（`drivers/reset/core.c`）。defconfig では `=m` で、rootfs にモジュールを入れていないと永久に待つ。1 回目の起動（`bootlog.txt`、22:13）はこれで止まった：`sdio-pwrseq: deferred probe pending: pwrseq_simple: reset control not ready` が出て SDIO ホストの probe が繰り返され、カードの検出まで進まず `wlan0` が無い。`=y` にした。DT で `reset-gpios` を持つのはパネル（nodisp 版では無効）と `sdio-pwrseq` だけなので、影響はこの 2 つに限られる。

**rootfs に追加するもの：**

- `make_wifi_stage.sh` が `wifi_stage/wifi-rootfs.tar` を作り、§7.7 で rootfs に展開する。中身は次のとおり。`make modules` の全モジュールは入れない。入れると udev が rk817_charger などを ODROID-Go の値のまま読み込む（§10.11）

| 中身 | 出所 |
|---|---|
| cfg80211・mac80211・rfkill・libarc4・rk915 のモジュールと depmod の結果 | カーネルのビルドと `rk915/` |
| `rockchip/rk915_fw.bin`・`rk915_patch.bin` | `rk915/firmware/` |
| `wpa_supplicant`・`iw`・`wireless-regdb` の全ファイル、`libpcsclite.so.1` | `pkgs/` の Arch Linux ARM パッケージをファイルとして展開 |
| `multi-user.target.wants/` の `wpa_supplicant@wlan0.service`・`dhcpcd@wlan0.service` | スクリプトが作るシンボリックリンク |
| `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`（接続先なし、600） | スクリプトが作る |
| `/etc/conf.d/wireless-regdom` の `WIRELESS_REGDOM="JP"` | wireless-regdb のファイル（全行コメント）をスクリプトが書き換える（2026-09-24 追記） |

- ユーザー空間を pacman でなくファイルとして入れる理由：rootfs の tarball には `netctl`・`dhcpcd` はあるが WPA の認証に使うものが無く、実機で `pacman -U` する手順は新しいカードで再現できない。ホストから pacman を動かすには ARM のエミュレーション（qemu-user-static）が要り、大がかりになる。`wpa_supplicant` の実行時依存は `libnl`・`openssl`・`libdbus`・`libpcsclite.so.1` で（`readelf -d` で確認）、前 3 つは rootfs にあり、`libpcsclite.so.1` は libc 以外に依存しない。`pcsclite` の残りと、その依存の `polkit`・`duktape` は pcscd デーモン用で不要。4 パッケージとも導入スクリプト（`.INSTALL`）を持たない
- 代償：pacman はこれらを「入っている」と知らない。後で `pacman -S wpa_supplicant iw wireless-regdb` をするなら `--overwrite '*'` が要る
- 初回（2026-09-22）は実機で `pacman-key --init` → `pacman -U` で入れた。そのとき分かったこと：tarball の pacman は鍵束が未初期化（`Public keyring not found`）、実機の時計は RTC から合わず systemd が 2026-01-07 に合わせるだけなので新しい署名を検証できない、`pacman -U` の後処理で mkinitcpio が `/boot` に initramfs を書いて FAT を満杯にした。最後の件は fstab で BOOT を `/boot/firmware` に載せることで根本から避ける（§7.7）

**既知の問題（ROCKNIX PR #3252 / #3251 の記述。本機では未確認）：**

- ファームウェアのエラー後、再ダウンロードが失敗し、モジュールを読み込み直すまで接続が戻らない。ROCKNIX は dmesg を監視して読み込み直すスクリプトで回避している
- 負荷をかけ続けてチップが応答しなくなると、dw_mmc の割り込みが止まらなくなって本体ごと固まることがある。対策パッチ（PR #3251、未マージ）は入れていない

**実機での確認手順：**

```bash
dmesg | grep -i -E "mmc1|sdio|rk915|cfg80211"   # SDIO カードの認識とドライバの読み込み
lsmod | grep rk915
ip link                                          # wlan0 があるか
ip link set wlan0 up && iw dev wlan0 scan | grep SSID
```

**結果（2 回目の起動、`CONFIG_RESET_GPIO=y`、カーネル `6.19.0-gfb5ef0332d8f-dirty`）：** 1.83 秒で `mmc1: new high speed SDIO card at address 0001`、17.9 秒で udev が `rk915` を読み込み `wlan0` ができた。ファームウェアはインターフェースを上げたときに転送される（`rk915: firmware patch 2_1_2`）。スキャンで周囲の SSID が見え、WPA2 で認証・関連付けし、DHCP でアドレスを得て、`ping archlinuxarm.org` が 3/3 応答した。SDIO のクロックは 50MHz で開始し、接続時にドライバが 40MHz に下げる。host-wake を GPIO0 A1 の LEVEL_HIGH とした DT のままで受信できている。

**追記（2026-09-24、ssh で実機を調べて分かったこと）：**

- **MAC が起動ごとに変わる。** `wlan0` の MAC が起動のたびに違い（`0a:47:…`、`26:75:…`）、DHCP サーバが前回のリースを NAK して IP が変わった（.110 → .111）。原因は `rk915/src/umac_if.c` の `init_mac_addr()`：DT に MAC が無いと `eth_random_addr()` で決める。`wifi@1` に `local-mac-address` を書いて固定した（上の DT 表）。ドライバは P2P 用の 2 つ目のアドレスをこの値から派生させる（先頭バイト + 4 → `06:…`）。
- **regulatory.db が読めていない。** 起動時に `cfg80211: loaded regulatory.db is malformed or signature is missing/invalid` が出て、国コードが `00`（世界共通の最も厳しい規則）のままだった。ファイル（`wireless-regdb 2026.09.03`、形式版 20）と署名（`wens` 鍵、カーネルにも同じ鍵が入っている）はホストの openssl で検証できるので正しい。原因はカーネル側：署名の照合に使う sha256 が `CONFIG_CRYPTO_SHA256=m` で、そのモジュールを rootfs に入れていない。実機の `/proc/crypto` に sha256 が無く、`iw reg reload` も `No data available` で失敗する。`CONFIG_CRYPTO_SHA256=y` にした（`scripts/diffconfig` で差分はこの 1 件のみ）。実害は 2.4GHz の 12・13ch と出力上限だけで、RK915 は 2.4GHz 専用なので接続には影響していなかった。
- **国コードの設定。** wireless-regdb の udev ルール（`85-regulatory.rules`）は cfg80211 の読み込み時に `set-wireless-regdom` を実行し、`/etc/conf.d/wireless-regdom` が全行コメントだと終了コード 1 でログに残る。`make_wifi_stage.sh` が `WIRELESS_REGDOM="JP"` を有効にするようにした。DB が読めるようになって初めて効く。
- 確認方法（実機）：`ip link show wlan0` の MAC が DT の値、`dmesg | grep regulatory` にエラーが無い、`iw reg get` が `country JP`。**2026-09-26 に実機で確認済み**（カーネル #17）：MAC は DT の値、IP は `<IP>` で固定、regulatory.db のエラーは消え `country JP: DFS-JP`、`/proc/crypto` に sha256 あり、`set-wireless-regdom` の失敗ログなし。

### 10.14 GUI：sway と自作のスティックデーモン（2026-09-23、実機で動作確認）

**構成：**

| 役割 | 実体 |
|------|------|
| 合成器 | `sway`（wlroots）。simpledrm の上で CPU 描画（`WLR_RENDERER=pixman`）。`/usr/local/bin/start-sway` が `seatd-launch` 経由で起動する |
| ターミナル | `foot`。設定は `/etc/xdg/foot/foot.ini` |
| スティックとカーソル | `r36u-joyd`（自作。`r36u_joyd.c`） |
| パッケージ | `fetch_pkgs.py` が依存を解決して `pkgs/gui/` に集め、`make_gui_stage.sh` が `gui_stage/gui-rootfs.tar` を作る。展開は §7.7 |

**スティックは 4 軸すべてが 1 本の ADC に多重化されている。** gpio2 の 2 本で切り替える。実機で 9 姿勢 × 8 通りを測って確定した値：

| B7（line 15） | C0（line 16） | 軸 | 一方の端 | 中立 | もう一方の端 |
|---|---|---|---|---|---|
| 0 | 0 | 左 X | 左 826 | 491 | 右 37 |
| 1 | 0 | 左 Y | 上 915 | 516 | 下 105 |
| 1 | 1 | 右 X | 左 45 | 515 | 右 850 |
| 0 | 1 | 右 Y | 上 169 | 508 | 下 901 |

- 純正 DT の `gamepad` ノードにある `rocker-gpios`（B7）・`rocker1-gpios`（C0）がこの 2 本。`rocker0-gpios`（gpio2 B3、line 11）は値に影響しなかったので触らない
- 純正 DT の `adc-chan = <0..3>` は実際の配線と対応しない。**この基板で ADC に出ている軸は ch1 だけ**で、ch0 は 512 固定、ch3〜ch5 は未接続の値（446 前後）
- **mainline の `adc-joystick` は使えない**（1 軸 = 1 チャンネル前提のため）。BSP は同じ多重化を独自ドライバ `micro,gamepad` の中で行っている
- 音量ボタンは ch2 の抵抗ラダー（無操作 1020、下 168、上 0）。純正の閾値と一致するが、DT にはまだ書いていない（残課題）

**`r36u-joyd`（`r36u_joyd.c`）：** 上の表のとおり GPIO を切り替えながら ch1 を読み、uinput で 2 つのデバイスを作る。

- `R36Ultra sticks`：4 軸（ABS_X/Y/RX/RY）。較正値は上の表、デッドゾーンは ±3500/32767、周期 10ms
- `R36Ultra pointer`：左スティックでカーソル（速度は変位の 2 乗に比例）、A で左クリック、B で右クリック。ボタンはカーネルの `gpio-keys-gamepad` から読む
- 依存を増やさないため、GPIO（`GPIO_V2_*` ioctl）も uinput もカーネルのインタフェースを直接使う。libgpiod にも依存しない
- `CONFIG_INPUT_UINPUT=y` が要る。`/etc/systemd/system/r36u-joyd.service` で自動起動（有効化のシンボリックリンクも tar に入れてある）

**カーネル側で足したもの（`.config`）：** `ROCKCHIP_SARADC`・`INPUT_UINPUT`・`KEYBOARD_ADC`・`INPUT_JOYSTICK`・`JOYSTICK_ADC` を `=y`。`JOYSTICK_ADC` は現状使っていない（多重化のため使えない）が、`KEYBOARD_ADC` は音量ボタンを DT に書くときに使う。

**フォント：** foot の既定（`monospace:size=8` = DejaVu Sans Mono）は、この画面では細く隙間が目立った。`Terminus`（ビットマップ、16px、90×45 文字）を既定にした。`JetBrains Mono` と `DejaVu Sans Mono` も入れてあり、`foot.ini` の 1 行を入れ替えれば切り替わる。Arch の fontconfig の既定設定にはビットマップフォントを無効化するものが含まれていないので、そのまま使える。

**glibc を上書きする必要があった：** rootfs の tarball（2026-01）は glibc 2.42 だが、今ビルドされているパッケージは 2.43 のシンボルを要求する（`foot` は `log10f@GLIBC_2.43`。`readelf --dyn-syms` で確認）。そのため overlay に glibc 2.43 も含める。`/etc` は除いて実機の設定を残す。展開は PC 側でカードをマウントして行うので、動作中のライブラリを置き換える危険はない。

**BOOT パーティションが満杯になった：** `Image` の待避コピーが `No space left on device` で失敗した。原因は `initramfs-linux-fallback.img`（146MB）と `initramfs-linux.img`（11MB）で、`pacman` の後処理で `/boot` に書かれたもの。今の起動設定は initramfs を読まないので削除した。根本対処は fstab で BOOT を `/boot/firmware` に載せること（§7.7）。

**実機で確認したこと（2026-09-23）：** 4 軸すべてが中立 0・両端 ±32767 で読める。左スティックでカーソルが動き、A・B でクリックできる。foot が Terminus で表示される。USB キーボードを挿しての入力もできた（USB ホストと VBUS が動いている）。

#### GUI の残り（2026-09-23 に追加）

| 要素 | 実体 | 確認状況 |
|------|------|----------|
| 画面キーボード | `wvkbd`（`wvkbd/`、PC でクロスビルド）。`-H 280`、起動時から表示、`Alt+k`（`osk-toggle`）で開閉 | 実機で表示・入力を確認 |
| 状態表示（小） | sway のバー（上端 20px）に `r36u-status` の 1 行 | 実機で確認 |
| 状態表示（大） | `Alt+i` で `foot --app-id=r36u-status r36u-status -f` を全画面（`for_window`） | 実機で確認 |
| LED | DT の `gpio-leds`。`/sys/class/leds/` から操作、状態表示の `r`/`g`/`b` でも切替 | 赤の点灯を確認 |
| 音量ボタン | DT の `adc-keys`（SARADC ch2） | 表示に項目はあるが、値の確認は未 |
| 電池 | DT の `simple-battery` + `CHARGER_RK817=y` | 表示に項目はあるが、値の確認は未 |

**表示の作り方（実機で直したこと）：** バーは押したボタンで文字数が変わると電池の数値が左右に動いてしまうので、**ラベルは常に全部出し、押下は色だけで表す**（`pango_markup enabled`）。十字キーは矢印（`← ↑ ↓ →`）。全画面表示は実機のボタン配置を模した図で、押下は反転表示、スティックは 2 次元の枠の中を点が動く。

**`make_sysroot.sh` → `sysroot/`（2.1GB）：** wvkbd のように自分でビルドするものが実機と同じ版に対してリンクできるよう、**rootfs の tarball の `/usr/include`・`/usr/lib` に `pkgs/gui` のパッケージを重ねた**ツリーを作る。`gui_stage/rootfs` とは別（あちらは tar に固めるので tarball のファイルを混ぜられない）。使い方は次のとおり。

```bash
PKG_CONFIG_SYSROOT_DIR=$PWD/sysroot \
PKG_CONFIG_LIBDIR=$PWD/sysroot/usr/lib/pkgconfig:$PWD/sysroot/usr/share/pkgconfig \
  make CC="aarch64-linux-gnu-gcc --sysroot=$PWD/sysroot"
```

**版の食い違いは pkg-config で洗い出せる：** 新しい `pango` は `glib2 >= 2.88` を要求するが、rootfs の tarball は 2.86.3 だった。overlay の全 `.pc` に対して `pkg-config --exists` を回すと、こうした不足が一覧で出る。見つかったものは `fetch_pkgs.py --refresh <名前>` で入れ替える（glibc と glib2 がそれ）。ELF のシンボル版（`GLIBC_2.43`）だけを見ても気づけない種類の不整合なので、両方見る。

**そのほか実機で分かったこと：**

- `gpioset` は終了するまで GPIO を掴む。実験の後に残っていると次の `gpioset` が `Device or resource busy` で失敗する（測定が丸ごと無駄になった）
- `gpiodetect` が出すチップのラベルは `gpio2` であって `ff260000.gpio` ではない
- 設定済みのカードに `wifi-rootfs.tar` を展開し直すと、実機で設定した SSID とパスワードが空の雛形で上書きされる。更新時は `--exclude='./etc/wpa_supplicant/*'` を付ける（tar にディレクトリ項目が無いので、末尾の `/*` が要る）
### 10.15 電源断・熱管理・RTC・電池ゲージ・fstab（2026-09-29、ssh で実機確認）

**変更（カーネル #18、DTB 同日）：**

- DT：pmic ノードに `system-power-controller;`（純正の `rockchip,system-power-controller` と同じ働き）。`rk8xx-core.c` はこの property があるときだけ RK817 の power-off / restart ハンドラを登録する。実機の DT に入っていることを確認し、同日 ssh から `systemctl poweroff` を打って**電源が切れることを確認**（作業者の目視。長押し不要）。journal は `Unmounted /boot/firmware` → `Reached target System Power Off` まで記録され、次の起動で journal・FAT とも clean。§10.11 の「正常 shutdown でも journal が unclean」はこれで解消したとみる
- `.config`：`ROCKCHIP_THERMAL=y`、`RTC_DRV_RK808=y`（どちらも `=m` でモジュール未搭載だった）

**結果：**

- 熱管理：`thermal_zone0` = soc-thermal（39.5℃）、`thermal_zone1` = gpu-thermal（40.5℃）、`cooling_device0`（CPU の cpufreq）。trip は `px30.dtsi` の 70/85℃ passive、115℃ critical。ドライバの警告「Missing tshut mode / tshut-polarity property, using default (cru / low)」は、純正 DT にも該当 property が無いので同じ既定
- RTC：`/dev/rtc0`（rk808-rtc）が出て `since_epoch` が進む。probe 時に「setting system clock to 2017-08-05」→ **RTC はそれまで止まっていた**（`rtc-rk808.c` の probe は `STOP_RTC` ビットを解除して RTC を走らせる）。NTP 同期後は `RTC_SYSTOHC` で RTC に書き戻され、`timedatectl` の RTC time が正しくなった
- **電池ゲージが動き出した**（§10.11 の「電圧・電流が更新されない」の解決）：#18 で電圧 3.555→3.578→3.580V、電流 +758→+870mA と更新、`status` = Charging、`capacity` 100%。レジスタ生値（`0x78-0x7b`）も 5 秒で変化。`ADC_CONFIG0` = 0xfc、`GG_CON` = 0x04 は #17 と同じ設定なので、変わったのは RTC が走ったこと。RK817 のガスゲージの平均値レジスタは RTC のクロックに依存すると解釈している（データシート未確認。#17 に戻して再現させる試験はしていない）
- fstab：v3 で BOOT を `/boot/firmware` に載せ替え（§7.7 の内容）。`findmnt` で `/boot/firmware` = mmcblk0p1、`/boot` は rootfs 側の通常ディレクトリ（`linux-aarch64` パッケージの `Image`・`initramfs-linux*.img` が見える）。`/root/.bashrc` の screenfetch の path も `/boot/firmware/` に変更
- FAT：ホストで `fsck.fat -a` を実行し、起動時の「Volume was not properly unmounted」が消えた（0 件）
- 残骸：`Image.prejoystick` を削除。BOOT は Image・DTB 2 つ・extlinux・boot.ini・screenfetch.sh のみ
- カードの更新はスクリプト（fsck → 書き込みと `cmp` → fstab → wifi tar → umount → 読み直して再 `cmp`）で行い、同期は `sync -f <マウント先>` のみ（§7.7）

**WiFi の限界（同日）：** ssh で #19 の `Image`（53MB）を実機へ流したところ、約 900KB で止まり、実機の dmesg に `rk915: fw error recovery (0) start`、`tx_thread: ret = -16`、`requesting mac80211 restart` が出た。§10.13 の既知の問題（負荷でファームウェアがエラー）の実例。回復後は 2MB の転送も完了しなくなる（小さな ssh コマンドは通る）。以後、大きなファイルの反映は原則カードを PC に挿して行う（`sync -f` 方式）。再起動直後なら 2MB を 1MB/s に絞って送ると通るが、53MB では 5 分で 16.5MB しか届かず、その間に fw error recovery が 17 回起きた。**絞っても駄目。** ssh は小さなコマンドと実機→ホストの採取に限る

**GPU（カーネル #19、同日）：** `DRM_PANFROST=y`（依存で `DRM_SCHED=y`）。DTB は変わらない。実機で panfrost が `mali-g31 id 0x7093` を認識し、`/dev/dri/card1`・`renderD128`、devfreq `ff400000.gpu`（200MHz、simple_ondemand）、thermal の `cooling_device1` = devfreq-GPU が出た。`vdd_logic` は GPU の OPP に従って 0.95V（純正の GPU OPP 表も同じ電圧）。sway は `start-sway` の `WLR_RENDERER=pixman` のままなので、合成器の描画はまだ CPU。GPU 描画への切替（`WLR_RENDERER` を外して `WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128`）は表示先が simpledrm のため動くか不明で、画面を見ながら別途試す

**電池ゲージの残量：** ゲージが動き出した直後は残量の値が当てにならない（2026-09-29: USB を抜いた状態で `capacity` 98% なのに電圧 3.41V・放電 0.43A）。クーロンカウンタが長期間止まっていたため。一度満充電（充電器が終止するまで）して較正する → **2026-09-30 に実施**：一晩 USB 給電で `status=Full`、4.066V、+8mA、`charge_now` = `charge_full` = 2832mAh、`CHRG_STS` の充電段階 = 4（終止）。以後の残量は満充電基準のクーロン計数

**pacman と Landlock（2026-09-30、カーネル #20）：** 実機で `pacman -Syu` が `restricting filesystem access failed because Landlock is not supported by the kernel!` → `switching to sandbox user 'alpm' failed!` で止まった。rootfs の pacman 7.1 はダウンロードを `alpm` ユーザー + Landlock のサンドボックスで行うが、`.config` に `CONFIG_SECURITY_LANDLOCK` が無かった（`CONFIG_LSM` の一覧に "landlock" はあるが本体が無く、`/sys/kernel/security/lsm` は `capability` のみ）。`SECURITY_LANDLOCK=y`（依存で `SECURITY_NETWORK`・`SECURITY_PATH`）にした。暫定策は `/etc/pacman.conf` の `DisableSandboxFilesystem` を有効にすること（`alpm` ユーザーと seccomp は残る）。`-Syu` の注意：BOOT が `/boot/firmware` なので `linux-aarch64` の更新で自作 Image は上書きされない。tar で入れたユーザー空間は pacman が把握していないので、更新後に sway が動くか確認し、駄目なら gui tar を展開し直す

**未実施：** sshd の stage 化（`make_wifi_stage.sh` へのパッチは作成済み。自動モードの制限で私（Claude）は適用できないので作業者が当てる）

