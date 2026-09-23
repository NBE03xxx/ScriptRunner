# Script Runner 開発文書

## 1. 概要

Script Runnerは、Ubuntu 26.04上でシェルスクリプトを管理・実行するGTK4デスクトップアプリである。

FastAPIバックエンドはsystemdユーザーサービスとして常駐し、GTK4＋WebKitGTK 6.0の画面はアプリケーションメニューから必要時に起動する。画面は既存のHTML / CSS / JavaScriptを利用するが、外部ブラウザは使用しない。

詳細計画は`DESKTOP_APP_PLAN.md`、作業状況は`IMPLEMENTATION_PROGRESS.md`、引き継ぎ情報は`HANDOFF_PROMPT.md`を参照する。

## 2. 対応環境

- Ubuntu 26.04 LTS
- Python 3.14系
- GTK 4
- WebKitGTK 6.0
- PyGObject
- systemdユーザーサービス
- Wayland、X11フォールバック

対象OSを限定しているため、他ディストリビューションや他OS向けの互換レイヤーは追加しない。

## 3. コード構成

```text
app/
├── main.py       # FastAPI、API、解析、ファイル管理
├── service.py    # systemdサービス用Uvicorn起動
├── runtime.py    # 動的ポートと接続情報
├── desktop.py    # GTK4＋WebKitGTKアプリ
├── terminal.py   # GUIセッションでのターミナル起動
└── static/
    ├── index.html
    ├── app.js
    ├── style.css
    └── アイコン

tests/            # 自動テスト
install.sh        # インストール・更新
uninstall.sh      # アンインストール
config.json       # スクリプト保存先
white_list.txt    # 任意の実行許可リスト
```

## 4. 責務境界

### FastAPIサービス

- スクリプト一覧、読込、作成、保存、削除
- パス検証
- Group / Tag、SSHホスト、更新日時の解析
- ホワイトリスト判定
- SSH 22番ポートの死活確認
- デスクトップセッション認証
- 静的フロントエンド配信

GUI環境変数やターミナル起動は担当しない。

### GTKアプリ

- 単一起動
- 最大化ウィンドウ
- WebKitGTK画面
- 接続情報読込と再接続
- ナビゲーション制限
- Runメッセージ処理
- 現在のGUI環境でのターミナル起動

GTKアプリ終了時にFastAPIサービスは停止しない。

## 5. サービス起動

通常起動は次を使用する。

```bash
python3 -m app.service
```

起動処理は次の順序で行う。

1. 一時トークンとインスタンスIDを生成する。
2. `127.0.0.1:0`へソケットをバインドする。
3. バインド済みソケットをUvicornへ渡す。
4. FastAPIのstartup完了を待つ。
5. 接続情報を原子的に公開する。
6. 終了時に自身のインスタンスの接続情報だけを削除する。

ポート番号の取得後に別プロセスへ奪われる競合を避けるため、ポート番号だけを調べてソケットを閉じる実装は禁止する。

## 6. ランタイム接続情報

保存先:

```text
$XDG_RUNTIME_DIR/script-runner/connection.json
```

ディレクトリは`0700`、ファイルは`0600`とする。シンボリックリンク、他ユーザー所有、過剰な公開権限を拒否する。

現在のスキーマ:

```json
{
  "schema_version": 1,
  "pid": 1234,
  "host": "127.0.0.1",
  "port": 49152,
  "token": "起動ごとのランダム値",
  "instance_id": "一意なインスタンスID",
  "started_at": 0.0
}
```

GTKアプリはホストが`127.0.0.1`であること、ポート範囲、スキーマ、トークン、インスタンスIDを検証する。さらに認証付き`/api/health`を呼び、応答のインスタンスIDが接続情報と一致した場合に画面を開く。

## 7. 認証

デスクトップモードでは次の方式を使用する。

1. GTKアプリが所有者限定の`connection.json`を読む。
2. `/desktop/bootstrap/{token}`へ接続する。
3. FastAPIがトークンを一定時間比較で検証する。
4. `HttpOnly`、`SameSite=Strict`のセッションCookieを設定する。
5. `/`へリダイレクトする。
6. 以降のAPI呼出しはCookieで認証する。

JavaScriptやlocalStorageへ一時トークンを渡さない。サービス再起動時にはトークンが変わり、以前のセッションは無効になる。

## 8. API

| メソッド | パス | 説明 |
|---|---|---|
| GET | `/api/token-required` | UI起動モードを返す |
| GET | `/api/health` | 認証済みクライアントへサービスのインスタンスIDを返す |
| GET | `/api/scripts` | スクリプト一覧 |
| GET | `/api/read/{filename}` | 内容取得 |
| GET | `/api/execution-target/{filename}` | 最新の実行許可と検証済み対象を返す |
| POST | `/api/create/{filename}` | 排他的な新規作成 |
| POST | `/api/save/{filename}` | 既存ファイル保存 |
| DELETE | `/api/delete/{filename}` | 削除 |
| GET | `/api/ping` | SSHポート死活確認 |
| GET | `/desktop/bootstrap/{token}` | GTKアプリのセッション確立 |

デスクトップ版のRun操作は`/api/execute`ではなく、WebKitGTKのスクリプトメッセージを使用する。

## 9. WebKitGTK連携

JavaScriptは`window.webkit.messageHandlers.runScript`が存在する場合、ファイル名だけをネイティブ側へ送る。

GTK側は認証付きで`/api/execution-target/{filename}`へ問い合わせ、バックエンドの最新のホワイトリスト判定を通過した対象だけを受け取る。その後、GTK側でも次を再検証する。

- 単一の`.sh`ファイル名であること
- 設定済みスクリプトディレクトリ内にあること
- 通常ファイルとして存在すること
- バックエンドの`white_list.txt`判定を通過していること

JavaScriptからコマンドラインや任意パスを受け取ってはならない。

## 10. ターミナル起動

検出順:

1. kitty
2. alacritty
3. foot
4. gnome-terminal
5. xfce4-terminal
6. konsole
7. xterm
8. ptyxis

引数は配列として`subprocess.Popen`へ渡す。シェル文字列を実行しない。単一文字列を要求する端末では`shlex.join`で引用する。

ターミナルは新しいセッションとして起動し、GTKアプリ終了後も継続可能にする。

## 11. スクリプトメタデータ

先頭30行のコメントから次を取得する。

```bash
# group: グループ名
# tag: タグ名
```

- Groupは最初の有効値
- Tagは初出順、完全一致で重複除外
- 大文字・小文字を区別しないキー
- 空値を除外
- 日本語可

SSHホスト解析はファイル全文を対象とし、コメント行を除外する。

## 12. インストール

`install.sh`は以下を行う。

- Ubuntu 26.04確認
- Python、Git、systemd確認
- GTK4 / WebKitGTK 6.0 GI名前空間確認
- スクリプト保存先選択
- `--system-site-packages`付きvenv作成
- Python依存関係導入
- `script-runner.service`生成
- デスクトップエントリーとアイコン配置
- サービス有効化・起動
- 接続情報確認

固定ポート、SECRET_TOKEN、GUI環境変数は設定しない。`loginctl enable-linger`も実行しない。

## 13. アンインストール

`uninstall.sh`は以下を行う。

- サービス停止・無効化
- サービスファイル削除
- デスクトップエントリーとアイコン削除
- ランタイム接続情報削除
- 設定とスクリプトの任意バックアップ
- プロジェクトディレクトリ削除

外部スクリプトディレクトリは削除しない。

## 14. テスト

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
python3 -m py_compile app/*.py
node --check app/static/app.js
bash -n install.sh uninstall.sh
```

テスト対象:

- 排他的作成とファイル名検証
- Group / Tag / SSH解析
- ホワイトリスト
- ランタイムディレクトリと接続情報権限
- 原子的接続情報更新
- インスタンス一致削除
- ループバック動的ソケット
- デスクトップセッション認証
- ターミナル引数構築

ソケット作成を禁止するサンドボックスでは該当テストをスキップし、権限付きローカル環境で別途実行する。

## 15. コーディングルール

- PythonはPEP 8を基準とする。
- 公開関数と重要な内部関数へdocstringを付ける。
- コメントと利用者向け文言は原則日本語とする。
- フロントエンドはHTML / CSS / JavaScriptを分離する。
- 秘密情報をログへ出力しない。
- パス、所有者、ファイル種別、権限を検証する。
- ファイル更新は可能な範囲で原子的に行う。
- GUIスレッドをネットワーク待機や長時間処理でブロックしない。

## 16. 旧実装の整理

移行中に必要な旧実装だけを一時的に維持する。不要になったファイルは`old/`へ退避して参照を断ち、全回帰試験後に`old/`ごと削除する。

最終成果物に次を残さない。

- 固定8080番ポート前提
- `0.0.0.0`待受
- ブラウザ・お気に入り前提の手順
- `.env`へ固定したWayland / X11環境変数
- バックエンドからのGUIターミナル起動
- `loginctl enable-linger`
- 不要な`__pycache__`、`.pyc`、一時バックアップ

## 17. 変更履歴

- 2026-09-23: GTK4＋WebKitGTKデスクトップアプリへの移行を開始。動的ポート、ランタイム接続情報、一時セッション認証、GTKアプリ、ネイティブRun、デスクトップエントリーを実装。
- 2026-08-23: Group / Tag、新規作成、複数列UI、フォルダー選択、Wayland対応を追加。
- 2026-08-15: systemdユーザーサービスへ移行し、ローカルターミナル起動へ変更。
- 2026-07-24: 初期実装。
