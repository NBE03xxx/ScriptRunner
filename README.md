# Script Runner

Ubuntu 26.04上でシェルスクリプトを一覧・編集・実行する、GTK4＋WebKitGTKのデスクトップアプリです。

外部ブラウザ、URL入力、ブックマークは使用しません。アプリケーションメニューからScript Runnerを起動し、最大化された専用画面でスクリプトを選択します。

## 主な機能

- 指定フォルダー内の`.sh`ファイルを一覧表示
- Web UIを利用したスクリプトの新規作成・編集・削除
- GTKアプリからローカルターミナルを起動してスクリプトを実行
- `ssh user@host`からの接続先抽出とSSH 22番ポートの死活確認
- スクリプト冒頭コメントによるGroup / Tag分類
- 名前、更新日時、Groupによるソート
- Tagによる絞り込み
- `white_list.txt`による実行制限
- デスクトップ設定に合わせて起動するライト／ダークテーマと手動切替
- 画面内の「ヘルプ」から操作方法とアプリ情報を確認
- 画面幅に応じた1～3列表示

## 対応環境

- Ubuntu 26.04 LTS
- Waylandを標準サポート
- X11はフォールバック対応
- systemdユーザーサービスを利用可能なデスクトップセッション

他のLinuxディストリビューション、Windows、macOSは対象外です。

## アーキテクチャ

Script Runnerは、常駐バックエンドと必要時だけ起動するデスクトップ画面に分かれています。

```text
systemd --user
  └─ script-runner.service
       └─ FastAPI / Uvicorn
            ├─ 127.0.0.1の動的ポート
            └─ $XDG_RUNTIME_DIR/script-runner/connection.json

アプリケーションメニュー
  └─ GTK4アプリ
       └─ WebKitGTK 6.0
            └─ 現行HTML / CSS / JavaScript
```

- FastAPIサービスはログイン中に常駐します。
- GTKアプリを閉じてもFastAPIサービスは停止しません。
- GTKとWebKitGTKは画面を開いている間だけ動作します。
- ポートはサービス起動ごとにOSが動的に割り当てます。
- APIは`127.0.0.1`だけで待ち受け、LANには公開しません。
- 接続情報と一時トークンは`$XDG_RUNTIME_DIR`へ所有者限定で保存します。

詳細な設計は`DESKTOP_APP_PLAN.md`を参照してください。

## 必要なパッケージ

インストーラーを実行する前に、Ubuntuパッケージを導入してください。

```bash
sudo apt install \
  python3 python3-venv python3-gi python3-gi-cairo \
  gir1.2-gtk-4.0 gir1.2-webkit-6.0 libwebkitgtk-6.0-4
```

kitty、alacritty、foot、gnome-terminal、xfce4-terminal、konsole、xterm、ptyxisのいずれかも必要です。

## インストール

一般ユーザーのGUIセッションから実行します。`sudo ./install.sh`として実行しないでください。

```bash
./install.sh
```

インストーラーは次を行います。

- Ubuntu 26.04、GTK4、WebKitGTK 6.0の確認
- `~/ScriptRunner`へのアプリケーション配置
- スクリプト保存フォルダーの選択
- system-site-packagesを利用するPython仮想環境の作成
- systemdユーザーサービスの生成・有効化・起動
- デスクトップエントリーとアイコンの配置
- 動的接続情報の生成確認
- 認証済みヘルス応答とインスタンスIDの照合

固定ポート、SECRET_TOKEN、DISPLAY等の入力は不要です。インストール後、Ubuntuのアプリケーションメニューから「Script Runner」を起動します。

## アンインストール

```bash
./uninstall.sh
```

サービス、デスクトップエントリー、アイコン、ランタイム接続情報、アプリケーション本体を削除します。設定とスクリプトは削除前にバックアップを確認し、プロジェクト外のスクリプトフォルダーは削除しません。

## スクリプト保存先

保存先は`config.json`の`script_dir`で指定します。
新規取得直後など`config.json`がない場合は、同梱の`config.example.json`を読み込みます。

```json
{
    "script_dir": "/home/user/Scripts"
}
```

相対パスの場合はプロジェクトルートを基準に解決します。設定変更後はサービスを再起動してください。

```bash
systemctl --user restart script-runner
```

## Group / Tag

各スクリプトの先頭30行以内へコメントとして記述します。

```bash
#!/bin/bash
# group: Mastodon
# tag: ssh
# tag: maintenance

ssh mastodon@192.168.1.100
```

Groupは最初の有効な1件、Tagは重複を除いた全件を使用します。日本語も使用できます。

## 実行ホワイトリスト

プロジェクトルートの`white_list.txt`へ、実行を許可するファイル名を1行ずつ記述します。

```text
deploy.sh
backup.sh
restart_service.sh
```

- ファイル不存在または空ファイル: 全スクリプトを許可
- `none`のみ: 全スクリプトを拒否
- `#`で始まる行: コメント

許可されていないスクリプトは一覧へ表示されますが、Runは無効になります。

## サービス管理

```bash
systemctl --user status script-runner
systemctl --user restart script-runner
journalctl --user -u script-runner -f
```

接続情報は次の場所にあります。

```text
$XDG_RUNTIME_DIR/script-runner/connection.json
```

一時トークンが含まれるため公開しないでください。サービス停止時に削除され、次回起動時に再生成されます。

## セキュリティ

- FastAPIは`127.0.0.1`だけで待ち受けます。
- 動的ポートと起動ごとの一時トークンを使用します。
- 接続情報は`0700`のディレクトリと`0600`のファイルで管理します。
- デスクトップ画面はHttpOnlyセッションCookieを使用します。
- JavaScriptやlocalStorageへ秘密情報を保存しません。
- Run要求では実行直前にバックエンドへ最新の許可対象を問い合わせ、GTK側でも保存先と通常ファイルを再検証します。

## 開発

- `app/main.py`: FastAPI、ファイル管理、メタデータ解析
- `app/service.py`: systemdユーザーサービス用起動処理
- `app/runtime.py`: 動的ポートと接続情報
- `app/desktop.py`: GTK4＋WebKitGTKアプリ
- `app/terminal.py`: ターミナル起動
- `app/static/`: HTML、CSS、JavaScript
- `tests/`: 自動テスト

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
python3 -m py_compile app/*.py
node --check app/static/app.js
bash -n install.sh uninstall.sh
```

## ライセンス

MIT License。詳細は`LICENSE`を参照してください。
