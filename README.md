# Script Runner GUI

このリポジトリは、LAN内のサーバー群（PVE等）に配置されたシェルスクリプトを、ブラウザ上のWeb UIから直感的に管理・実行するためのツールです。

## 主な機能

- **スクリプト一覧表示**: インストール時に選択したフォルダー内の `.sh` ファイルを自動検出し、リストとして表示します。
- **リモート情報の抽出**: スクリプト内の `ssh root@xxx.xxx.xxx.xxx` の記述から、接続先ホストを自動解析して表示します。
- **Group / Tag分類**: スクリプト冒頭のコメントから Group / Tag を取得し、カード表示、Group順の並び替え、Tagによる絞り込みに利用できます。
- **Webエディタ機能**: ブラウザ上でスクリプトの新規作成・編集・保存ができます（`.sh` ファイルのみ）。新規作成時は `#!/bin/bash` が最初から入力されています。
- **ワンクリック実行**: 画面上の「Run」ボタンを押すだけで、ローカルターミナルエミュレータでスクリプトを起動します。利用可能なターミナル（kitty, alacritty, foot, gnome-terminal, xfce4-terminal, konsole, xterm, ptyxis）が Wayland ネイティブ優先の順に自動検出されます。
- **ホワイトリスト機能**: `white_list.txt` で実行許可するスクリプトを制限できます。無許可のスクリプトは Run ボタンが無効化されます。
- **ソート機能**: スクリプト名、更新日時、Groupによる並び替えが可能です。
- **テーマ切り替え**: ダークモードとライトモードの切り替えに対応しており、作業環境に合わせて調整できます。

## 技術スタック

- **Backend**: Python (FastAPI) + asyncio subprocess
- **Frontend**: HTML5, CSS3 (CSS Variables), JavaScript (Vanilla JS)
- **Web Server**: Uvicorn (ASGI server)
- **Deployment Target**: Linux (Local LAN environment)

## Group / Tag の指定

各 `.sh` ファイルの冒頭30行以内に、1行ずつコメントとして記述します。Groupは最初の有効な1件、Tagは重複を除いた全件が利用されます。指定がないスクリプトも従来どおり扱えます。

```bash
#!/bin/bash
# group: Mastodon
# tag: ssh
# tag: maintenance

ssh mastodon@192.168.1.100
```

一覧上部の「Tag」ドロップダウンで絞り込みでき、絞り込み中も名前・更新日時・Groupの並び替えを併用できます。Group / Tagの編集は従来のWebエディタでコメントを直接変更してください。

## ディレクトリ構造

- `app/main.py`: FastAPIによるバックエンドロジック。APIエンドポイント、スクリプトの読み書き、実行を管理。
- `app/static/index.html`: Web UI の HTML。
- `app/static/app.js`: フロントエンド JS（認証、一覧表示、実行、ホスト死活チェック等）。
- `app/static/style.css`: テーマ切替対応のスタイルシート。
- `config.json`: 起動設定ファイル。スクリプト配置ディレクトリを指定する。
- `white_list.txt`: ホワイトリスト機能で許可するスクリプト名のリストを管理するテキストファイル。
- `install.sh`: インストール・セットアップ用スクリプト（root不要、GUIセッションから実行）。
- `uninstall.sh`: アンインストール用スクリプト（root不要、GUIセッションから実行）。
- `config.example.json`: 設定ファイルの例。
- `requirements.txt`: Python 依存パッケージのリスト。
- `bin/`: インストール時に別のフォルダーを選択しなかった場合の、既定のスクリプト配置ディレクトリ。実際の保存先は `config.json` の `script_dir` で指定される。新規ファイルは UI の「新規作成」から追加できる。

## 前提条件

- Linux 上の GUI セッション（**Wayland を正式サポート**、X11 はフォールバック）が起動していること
- `python3` と `python3-venv`（および対応するバージョンの `python3.X-venv`）がインストールされていること
  - Ubuntu/Debian の場合: `sudo apt install python3-venv`（Python 3.14 では `python3.14-venv`）
  - この作業は **root 権限を必要とします**。インストール前に一度だけ行ってください
- ターミナルエミュレータ（kitty, alacritty, foot, gnome-terminal, xfce4-terminal, konsole, xterm, ptyxis のいずれか）がインストールされていること
- フォルダー選択ダイアログには `zenity`（Ubuntu標準）または `kdialog` を使用。どちらもない場合は端末入力へ自動的に切り替わる

## インストール方法

1. **インストールスクリプトを実行**

    ```bash
    ./install.sh
    ```

    スクリプトは以下を自動で実行します:

    - リポジトリのクローン（`~/ScriptRunner`）
    - Python 仮想環境の作成と依存パッケージのインストール
    - 既定の `~/ScriptRunner/bin` を作成してから、スクリプト保存フォルダーを選択
    - `config.json` と `.env` の生成（SECRET_TOKEN と LISTEN_PORT を入力）
    - 端末ロケールに応じた日本語・英語表示の自動切り替え
    - systemd ユーザーサービスファイルの配置・有効化・起動
    - WAYLAND_DISPLAY / DISPLAY / XAUTHORITY の自動検出（Wayland 優先、X11 フォールバック）

Ubuntu標準デスクトップではZenityのフォルダー選択画面が開きます。KDEではKDialogを使用し、GUIツールが見つからない場合は端末上で保存先を入力します。再インストール時は現在の `script_dir` が既定値として引き継がれます。

表示言語は `LC_ALL`、`LC_MESSAGES`、`LANG` の順で判定され、`ja` から始まるロケールでは日本語、それ以外では英語になります。必要な場合は環境変数で明示指定できます。

```bash
SCRIPT_RUNNER_LANG=ja ./install.sh
SCRIPT_RUNNER_LANG=en ./uninstall.sh
```

> **注意**: install.sh 自体は root 権限を必要としませんが、GUI セッションから実行してください（上記の `python3-venv` のインストールのみ root 権限が必要です）。選択先には、実行ユーザーが読み取り・書き込みできるフォルダーを指定してください。

2. **アクセス**

    インストール完了後、ブラウザから以下のURLにアクセスします:

    ```
    http://<your-host>:<port>
    ```

## アンインストール

```bash
./uninstall.sh
```

設定ファイルや、設定されたフォルダー内のスクリプトのバックアップを尋ねられます。確認後、サービスとプロジェクトディレクトリが削除されます。プロジェクト外に指定したスクリプトフォルダーとその内容は削除されません。

## systemd サービスの管理

インストール後は systemd ユーザーサービスで管理されています。以下のコマンドで操作できます:

```bash
# 状態確認
systemctl --user status script-runner

# 停止 / 起動
systemctl --user stop script-runner
systemctl --user start script-runner

# ログ確認
journalctl --user -u script-runner -f
```

### サービス定義の内容

install.sh はリポジトリのテンプレートではなく、実行環境に応じて `~/.config/systemd/user/script-runner.service` を**直接生成**します。生成される内容は以下の通りです（`${INSTALL_DIR}` は `~/ScriptRunner`）:

```ini
[Unit]
Description=Script Runner GUI
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/venv/bin/python app/main.py
Restart=on-failure
RestartSec=5

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=script-runner

[Install]
WantedBy=default.target
```

- `EnvironmentFile` により `.env`（SCRIPT_RUNNER_TOKEN, UVICORN_PORT, WAYLAND_DISPLAY, DISPLAY, XAUTHORITY, XDG_SESSION_TYPE）を読み込みます。
- `WantedBy=default.target` により、ユーザーログイン時に自動起動します。
- 必要に応じて `loginctl enable-linger <user>` を実行すると、ログインなしでもサービスが起動し続けます（install.sh はこれを best-effort で実行します）。

## 🔐 認証トークンの設定

認証トークンは `.env` ファイルの `SCRIPT_RUNNER_TOKEN` 環境変数で管理します。install.sh の実行時にSECRET_TOKENを入力すると、自動的に `.env` に設定されます。

```bash
# プロジェクトルートに .env を作成（手動設定時）
echo 'SCRIPT_RUNNER_TOKEN=your-secure-token-here' > .env
```

> **注意**: `.env` は `.gitignore` で除外されています。誤ってコミットしないよう、各自で設定ファイルを作成してください。

> **⚠️ 重要**: `SCRIPT_RUNNER_TOKEN` を設定しないと、LAN 内の**誰でも**スクリプトの実行・編集・削除が可能になります。本ツールは**お一人様用のクライアント PC 前提**で設計されており、サーバー等への公開設置は想定していません。無効化される場合は自己責任でお願いします。

## ホワイトリスト機能（実行制限）

`white_list.txt` に許可するスクリプト名を1行に1つずつ記述することで、実行できるスクリプトを制限できます。ファイルが存在しない場合は全スクリプトの実行が許可されます。

```plaintext
deploy.sh
backup.sh
restart_service.sh
```

- **ファイル不存在**: 全スクリプトの実行が許可される。
- **空ファイル**: 全スクリプトの実行が許可される。
- **`none` のみ記載**: 一切実行できない（全てブロック）。
- 各行の先頭の `#` はコメントとして無視されます。
- 無許可のスクリプトは UI 上で Run ボタンが無効化され、API から実行しようとすると `403 Forbidden` が返されます。

## ターミナルエミュレータの自動検出

スクリプト実行時に、以下のターミナルエミュレータを **Wayland ネイティブ優先**の順に自動検出し、利用可能なものを使用します：

| 優先度 | ターミナル | Wayland 対応 | 対応オプション |
|--------|-----------|-------------|--------------|
| 1 | kitty | ネイティブ | `--single-instance bash <script>` |
| 2 | alacritty | ネイティブ | `--command bash <script>` |
| 3 | foot | ネイティブ | `-e bash <script>` |
| 4 | gnome-terminal | Xwayland 経由 | `-- bash <script>` |
| 5 | xfce4-terminal | Xwayland 経由 | `-e "bash <script>"` |
| 6 | konsole | Xwayland 経由 | `-e bash <script>` |
| 7 | xterm | Xwayland 経由 | `-e bash <script>` |
| 8 | ptyxis | Xwayland 経由 | `--new-window -e bash <script>` |

### GUI セッションの自動検出

`WAYLAND_DISPLAY` / `DISPLAY` / `XAUTHORITY` は以下の優先順で自動検出されます：

1. **環境変数**（`WAYLAND_DISPLAY`, `DISPLAY`, `XAUTHORITY`）
2. **`/run/user/$UID/wayland-*`** の存在（Wayland セッション）
3. **`/run/user/$UID/.mutter-Xwaylandauth.*`**（GNOME on Wayland の Xwayland 認証ファイル）
4. **`~/.Xauthority`**（X11 フォールバック）

Wayland セッションが検出された場合は `XDG_SESSION_TYPE=wayland` が子プロセスに設定され、X11 のみ環境では `XDG_SESSION_TYPE=x11` が設定されます。

## 📝 開発履歴・変更ログ
- **2026-08-23**: Web UIにスクリプトの「新規作成」を追加。本文へ `#!/bin/bash` を初期入力し、同名ファイルを上書きしない排他的作成とファイル名検証に対応。
- **2026-08-23**: 死活確認を修正。`ptyxis --new-window -- ssh user@host` 形式から接続先を抽出できず全件 `Unknown` になっていた問題を解消。初期表示時の一覧取得と死活確認の競合を防ぎ、不明なホストをオフラインと誤表示しないよう改善。
- **2026-08-23**: `install.sh` と `uninstall.sh` の表示言語を端末ロケールに応じて日本語・英語へ自動切り替えする機能を追加。`SCRIPT_RUNNER_LANG=ja|en` による明示指定にも対応。
- **2026-08-23**: フォルダー選択ダイアログを開く前に、既定の `~/ScriptRunner/bin` を作成するようインストール順序を修正。初回インストール時にZenityが存在しない初期フォルダーについて警告する問題を解消。
- **2026-08-23**: インストール時のスクリプト保存フォルダー選択に対応。UbuntuではZenity、KDEではKDialogを使用し、GUIツールがない場合は端末入力へフォールバックする。絶対パスを `config.json` に安全に保存し、再インストール時は既存設定を維持する。アンインストールではプロジェクト外の保存先を削除せず、任意バックアップのみ行う。
- **2026-08-23**: 修正。ステータスメッセージの表示をヘッダー右端スロットのみに統一し、一覧上部の重複表示（`#status-message`）を削除。キャッシュバスターを `?v=8` に更新。
- **2026-08-23**: 修正。起動メッセージ（「Script Runner に接続しました」）の表示位置がずれていた問題を解消。`#startup-message` を `position: fixed` に変更し、常時画面の右上に表示されるようにした。キャッシュバスターを `?v=7` に更新。
- **2026-08-23**: Wayland 環境の正式サポート。ターミナル検出順を Wayland ネイティブ優先（kitty, alacritty, foot, gnome-terminal, xfce4-terminal, konsole, xterm, ptyxis）に変更し `foot` を追加、kitty は `--single-instance` 起動。GUI セッション検出に `/run/user/$UID/wayland-*` ベースの Wayland 検出と `XDG_SESSION_TYPE` 設定を追加（X11 はフォールバック）。`install.sh` の `.env` 生成も Wayland 優先に修正。
- **2026-08-23**: ドキュメント整合。README / DOCUMENTS の記載を実装と照合し修正（ファイル名、ターミナル検出順、新規ファイル作成不可の明記、`SCRIPT_RUNNER_TOKEN` 未設定時のリスク注意書き追加）。バックエンドではホスト解析をコメント行除外対応に改善し、`shutil` の重複 import を整理した。
- **2026-08-22**: UI 改善。ヘッダー（タイトル・テーマ切替・並び替え）をスクロールしても固定表示（sticky）にし、起動メッセージ（「Script Runner に接続しました」）をヘッダー右端に常設表示するよう変更。ステータスメッセージは従来どおり一覧上部にも表示される（4 秒で自動消滅）。
- **2026-08-15**: ドキュメント修正。systemd サービスを install.sh が直接生成する user スコープ定義であること（WantedBy=default.target、.env 読み込み）を README に追記。system サービス時代のテンプレート `script-runner.service` を削除。`install.sh`/`uninstall.sh` の root 権限記述を実態（root不要）に修正。
- **2026-08-15**: README を更新。前提条件（`python3-venv`）を追記し、インストール先を `~/ScriptRunner` に修正、ターミナル検出順を実装と一致させた。
- **2026-08-15**: スクリプト実行を「ローカルターミナル起動」方式に変更。ptyxis, gnome-terminal など7種のターミナルエミュレータに対応。DISPLAY/XAUTHORITYの自動検出を追加（X11/Wayland対応）。
- **2026-08-15**: systemd サービスを system スコープから user スコープへ変更。サービスの実行に root 権限が不要になった（`python3-venv` のインストールのみ root 権限が必要）。
- **2026-08-14**: `start.sh` と `stop.sh` を廃止。systemd サービスのみに統一。
- **2026-08-14**: `install.sh` を見直し。サービスファイルをリポジトリテンプレートからコピーする方式に変更。ポートListen確認を追加。
- **2026-08-13**: ホワイトリスト機能を `config.json` から `white_list.txt` に変更。ファイルベースの管理に統一。
- **2026-08-13**: スクリプト実行を非同期サブプロセス（`asyncio.create_subprocess_exec()`）に変更。stdout/stderr/returncode を取得可能に。結果は `exec_id` ベースのポーリングでブラウザに表示されるように対応。
- **2026-08-13**: ホワイトリスト機能 (`execution_allowlist`) を追加。実行不可スクリプトの Run ボタンは無効化される。
- **2026-08-13**: `index.html` の不要な閉じタグを削除し、HTML バリデーションエラーを解消。
- **2026-08-13**: `/api/ping` に SCRIPT_DIR 存在チェックを追加し、ディレクトリ不存在時の例外を対策。
- **2026-08-13**: `/api/save/{filename}` に `.sh` 拡張子のバリデーションを追加し、不正なファイルの上書きを防ぐ。
- **2026-07-24**: プロジェクト初期化。
- **2026-07-24**: Webエディタ機能（ブラウザ上での編集・保存）を実装。
- **2026-07-24**: ダークモード/ライトモード切替、およびソート機能（名前/日付順）を追加し、UIの使いやすさを向上。
