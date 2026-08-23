#!/usr/bin/env bash
set -euo pipefail

_LOCALE="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
case "${SCRIPT_RUNNER_LANG:-}" in
    ja|en) UI_LANG="$SCRIPT_RUNNER_LANG" ;;
    "") [[ "$_LOCALE" == ja* ]] && UI_LANG="ja" || UI_LANG="en" ;;
    *) echo "SCRIPT_RUNNER_LANG must be 'ja' or 'en'." >&2; exit 1 ;;
esac

# ============================================================
# Script Runner GUI - Installation Script
# NOTE: Do NOT run with sudo. This installs as a user service.
# ============================================================

if [[ "$(id -u)" -eq 0 ]]; then
    echo ""
    if [[ "$UI_LANG" == ja ]]; then
        echo "エラー: sudo で実行しないでください。"
        echo "        Script Runner はユーザーサービスとしてインストールされます。"
        echo "        次のように一般ユーザーで実行してください:"
    else
        echo "ERROR: Do not run this script with sudo."
        echo "       Script Runner is installed as a user-level service."
        echo "       Run without sudo:"
    fi
    echo "         ./install.sh"
    echo ""
    exit 1
fi

INSTALL_DIR="${HOME}/ScriptRunner"
SERVICE_NAME="script-runner"
SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
REPO_URL="http://192.168.1.152:3000/yoshimi/ScriptRunner.git"

# Track what we've installed for rollback
CLONED=false
VENV_CREATED=false
CONFIG_CREATED=false
BACKUP_CONFIG=""
SERVICE_COPIED=false
ENV_CREATED=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

translate() {
    local text="$1"
    [[ "$UI_LANG" == en ]] && { printf '%s' "$text"; return; }
    case "$text" in
        "Rolling back changes...") printf '変更をロールバックしています...' ;;
        "Folder selection was cancelled.") printf 'フォルダー選択がキャンセルされました。' ;;
        "Use the default folder "*"?")
            local value="${text#Use the default folder }"
            value="${value%?}"
            printf '既定のフォルダー %s を使用しますか？' "$value"
            ;;
        "Installation cancelled.") printf 'インストールをキャンセルしました。' ;;
        "No GUI folder dialog is available. Enter the path in the terminal.") printf 'GUIフォルダー選択を利用できないため、端末でパスを入力してください。' ;;
        "The selected path is not a directory: "*) printf '選択したパスはディレクトリではありません: %s' "${text#*: }" ;;
        "The selected directory must be readable and writable: "*) printf '選択先には読み取り・書き込み権限が必要です: %s' "${text#*: }" ;;
        "===== Phase 1: Prerequisites =====") printf '===== フェーズ1: 前提条件の確認 =====' ;;
        "===== Phase 2: Configuration =====") printf '===== フェーズ2: 設定 =====' ;;
        "===== Phase 3: Installing files =====") printf '===== フェーズ3: ファイルのインストール =====' ;;
        "===== Phase 4: Activating service =====") printf '===== フェーズ4: サービスの有効化 =====' ;;
        "python3 is not installed.") printf 'python3 がインストールされていません。' ;;
        "git is not installed.") printf 'git がインストールされていません。' ;;
        "systemd is not available.") printf 'systemd を利用できません。' ;;
        "systemd: available") printf 'systemd: 利用可能' ;;
        "SECRET_TOKEN cannot be empty.") printf 'SECRET_TOKEN は空にできません。' ;;
        "Invalid port number: "*) printf '無効なポート番号です: %s' "${text#*: }" ;;
        "Port "*" is already in use. Please enter a different port.")
            local value="${text#Port }"
            value="${value%% is already*}"
            printf 'ポート %s は使用中です。別のポートを入力してください。' "$value"
            ;;
        "Configuration:") printf '設定内容:' ;;
        "Existing service file found: "*) printf '既存のサービスファイルを検出しました: %s' "${text#*: }" ;;
        "Overwrite existing installation?") printf '既存のインストールを上書きしますか？' ;;
        "Stopping existing "*) printf '既存のサービスを停止しています: %s' "${text#Stopping existing }" ;;
        "Legacy system-level service detected.") printf '旧形式のシステムサービスを検出しました。' ;;
        "Created "*) printf '作成しました: %s' "${text#Created }" ;;
        "Backed up existing config.json to "*) printf '既存の config.json をバックアップしました: %s' "${text#* to }" ;;
        "Cloning repository from "*) printf 'リポジトリをクローンしています: %s' "${text#* from }" ;;
        "Failed to clone repository.") printf 'リポジトリのクローンに失敗しました。' ;;
        "Cloned -> "*) printf 'クローン完了 -> %s' "${text#*-> }" ;;
        "app/main.py already exists. Skipping clone.") printf 'app/main.py が既に存在するため、クローンを省略します。' ;;
        "Prepared default script directory -> "*) printf '既定のスクリプトフォルダーを準備しました -> %s' "${text#*-> }" ;;
        "The folder selection dialog will open. Press Enter when ready:") printf 'スクリプトの保存先を選択します。準備ができたら Enter キーを押してください:' ;;
        "Opening the folder selection dialog...") printf 'フォルダー選択画面を開きます...' ;;
        "Failed to create script directory: "*) printf 'スクリプトフォルダーの作成に失敗しました: %s' "${text#*: }" ;;
        "Created script directory -> "*) printf 'スクリプトフォルダーを作成しました -> %s' "${text#*-> }" ;;
        "Using script directory -> "*) printf 'スクリプトフォルダーを使用します -> %s' "${text#*-> }" ;;
        "Script directory must be readable and writable: "*) printf 'スクリプトフォルダーには読み取り・書き込み権限が必要です: %s' "${text#*: }" ;;
        "Creating Python virtual environment...") printf 'Python仮想環境を作成しています...' ;;
        "Failed to create Python virtual environment.") printf 'Python仮想環境の作成に失敗しました。' ;;
        "Failed to install Python dependencies.") printf 'Python依存パッケージのインストールに失敗しました。' ;;
        "Installed dependencies -> "*) printf '依存パッケージをインストールしました -> %s' "${text#*-> }" ;;
        "Installed service file -> "*) printf 'サービスファイルを配置しました -> %s' "${text#*-> }" ;;
        "DISPLAY not set in current environment. Defaulting to :0") printf 'DISPLAY が未設定のため :0 を使用します。' ;;
        "Terminal launch: Wayland session "*) printf '端末起動: Waylandセッション %s' "${text#*session }" ;;
        "Terminal launch: X11 session "*) printf '端末起動: X11セッション %s' "${text#*session }" ;;
        "  XAUTHORITY="*" (for Xwayland apps)")
            local value="${text#*XAUTHORITY=}"
            value="${value% (for Xwayland apps)}"
            printf '  XAUTHORITY=%s（Xwaylandアプリ用）' "$value"
            ;;
        "  XAUTHORITY not detected — may need manual config") printf '  XAUTHORITYを検出できません。手動設定が必要な場合があります' ;;
        "No GUI session detected. Script execution via terminal will fail until .env is updated.") printf 'GUIセッションを検出できません。.envを更新するまで端末での実行は失敗します。' ;;
        "Existing system-level service found. Removing...") printf '既存のシステムサービスを削除しています...' ;;
        "Failed to reload user systemd daemon.") printf 'ユーザーsystemdデーモンの再読み込みに失敗しました。' ;;
        "Reloaded user systemd daemon") printf 'ユーザーsystemdデーモンを再読み込みしました' ;;
        "Failed to enable "*) printf '有効化に失敗しました: %s' "${text#Failed to enable }" ;;
        "Enabled "*) printf '有効化しました: %s' "${text#Enabled }" ;;
        "Starting "*) printf '起動しています: %s' "${text#Starting }" ;;
        "Failed to start "*) printf '起動に失敗しました: %s' "${text#Failed to start }" ;;
        "Installation completed but service did not start.") printf 'インストールは完了しましたが、サービスを起動できませんでした。' ;;
        "Check logs with:") printf '次のコマンドでログを確認してください:' ;;
        "Installation complete!") printf 'インストールが完了しました！' ;;
        "Service failed to start.") printf 'サービスの起動に失敗しました。' ;;
        "Service: "*) printf 'サービス: %s' "${text#Service: }" ;;
        "Access : "*) printf 'アクセス: %s' "${text#Access : }" ;;
        "Scripts: "*) printf 'スクリプト: %s' "${text#Scripts: }" ;;
        "Port   : "*" is listening")
            local value="${text#Port   : }"
            value="${value% is listening}"
            printf 'ポート: %s は待受中です' "$value"
            ;;
        "Port   : "*" - could not verify (service may still be starting)")
            local value="${text#Port   : }"
            value="${value% - could not verify (service may still be starting)}"
            printf 'ポート: %s の待受を確認できません（サービス起動中の可能性があります）' "$value"
            ;;
        "Port   : "*) printf 'ポート: %s' "${text#Port   : }" ;;
        "Status : "*) printf '状態確認: %s' "${text#Status : }" ;;
        "Logs   : "*) printf 'ログ: %s' "${text#Logs   : }" ;;
        "Stop   : "*) printf '停止: %s' "${text#Stop   : }" ;;
        "Start  : "*) printf '起動: %s' "${text#Start  : }" ;;
        "Removed "*) printf '削除しました: %s' "${text#Removed }" ;;
        "Restored "*) printf '復元しました: %s' "${text#Restored }" ;;
        *) printf '%s' "$text" ;;
    esac
}

info()    { echo -e "${GREEN}[INFO]${NC} $(translate "$*")"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $(translate "$*")"; }
error()   { echo -e "${RED}[ERROR]${NC} $(translate "$*")"; }

# ============================================================
# Rollback (best-effort cleanup on failure)
# ============================================================

rollback() {
    echo ""
    warn "Rolling back changes..."

    if [[ "$SERVICE_COPIED" == true ]]; then
        rm -f "$SERVICE_FILE" && info "Removed service file" || true
    fi

    systemctl daemon-reload 2>/dev/null || true

    if [[ "$ENV_CREATED" == true ]]; then
        rm -f "${INSTALL_DIR}/.env" && info "Removed .env" || true
    fi

    if [[ "$VENV_CREATED" == true ]]; then
        rm -rf "${INSTALL_DIR}/venv" && info "Removed venv directory" || true
    fi

    if [[ "$CONFIG_CREATED" == true ]]; then
        if [[ -n "$BACKUP_CONFIG" && -f "$BACKUP_CONFIG" ]]; then
            mv -- "$BACKUP_CONFIG" "${INSTALL_DIR}/config.json" && info "Restored config.json from backup" || true
        else
            rm -f "${INSTALL_DIR}/config.json" && info "Removed created config.json" || true
        fi
    fi

    if [[ -n "$BACKUP_CONFIG" && -f "$BACKUP_CONFIG" ]]; then
        rm -f "$BACKUP_CONFIG" || true
    fi

    if [[ "$CLONED" == true ]]; then
        rm -rf "$INSTALL_DIR" && info "Removed cloned directory" || true
    fi
}

# ============================================================
# Confirm prompt (y/n)
# ============================================================

confirm() {
    local message="$1"
    echo -n "$(translate "$message") [y/N]: "
    read -r answer
    case "$answer" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================
# Script directory selection
# ============================================================

normalize_path() {
    python3 - "$1" <<'PY'
import os
import sys

print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PY
}

read_configured_script_dir() {
    local config_path="${INSTALL_DIR}/config.json"
    [[ -f "$config_path" ]] || return 1

    python3 - "$config_path" "$INSTALL_DIR" <<'PY'
import json
import os
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as config_file:
        value = json.load(config_file).get("script_dir")
    if not isinstance(value, str) or not value.strip():
        raise ValueError
    if not os.path.isabs(value):
        value = os.path.join(sys.argv[2], value)
    print(os.path.abspath(os.path.expanduser(value)))
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    sys.exit(1)
PY
}

wait_for_folder_dialog() {
    if [[ -t 0 ]]; then
        read -erp "$(translate "The folder selection dialog will open. Press Enter when ready:") "
    else
        info "Opening the folder selection dialog..."
    fi
}

select_script_directory() {
    local default_dir="$1"
    local selected_dir=""
    local dialog_available=false

    if [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
        if command -v zenity &>/dev/null; then
            dialog_available=true
            wait_for_folder_dialog
            selected_dir=$(zenity --file-selection --directory \
                --title="$( [[ "$UI_LANG" == ja ]] && echo 'スクリプトを保存するフォルダーを選択' || echo 'Select the script storage folder' )" \
                --filename="${default_dir%/}/" 2>/dev/null) || selected_dir=""
        elif command -v kdialog &>/dev/null; then
            dialog_available=true
            wait_for_folder_dialog
            selected_dir=$(kdialog --getexistingdirectory "$default_dir" \
                --title "$( [[ "$UI_LANG" == ja ]] && echo 'スクリプトを保存するフォルダーを選択' || echo 'Select the script storage folder' )" 2>/dev/null) || selected_dir=""
        fi
    fi

    if [[ "$dialog_available" == true && -z "$selected_dir" ]]; then
        warn "Folder selection was cancelled."
        if confirm "Use the default folder ${default_dir}?"; then
            selected_dir="$default_dir"
        else
            error "Installation cancelled."
            exit 1
        fi
    elif [[ "$dialog_available" == false ]]; then
        warn "No GUI folder dialog is available. Enter the path in the terminal."
        if [[ "$UI_LANG" == ja ]]; then
            read -erp "  スクリプトフォルダー [${default_dir}]: " selected_dir
        else
            read -erp "  SCRIPT_DIRECTORY [${default_dir}]: " selected_dir
        fi
        selected_dir="${selected_dir:-$default_dir}"
    fi

    SCRIPT_DIR=$(normalize_path "$selected_dir")

    if [[ -e "$SCRIPT_DIR" && ! -d "$SCRIPT_DIR" ]]; then
        error "The selected path is not a directory: ${SCRIPT_DIR}"
        exit 1
    fi
    if [[ -d "$SCRIPT_DIR" && ( ! -r "$SCRIPT_DIR" || ! -w "$SCRIPT_DIR" || ! -x "$SCRIPT_DIR" ) ]]; then
        error "The selected directory must be readable and writable: ${SCRIPT_DIR}"
        exit 1
    fi
}

# ============================================================
# Phase 1: Prerequisites
# ============================================================

info "===== Phase 1: Prerequisites ====="

# User service — no root required

if ! command -v python3 &>/dev/null; then
    error "python3 is not installed."
    exit 1
fi
info "Python3: $(python3 --version)"

if ! command -v git &>/dev/null; then
    error "git is not installed."
    exit 1
fi
info "git: $(git --version)"

if ! command -v systemctl &>/dev/null; then
    error "systemd is not available."
    exit 1
fi
info "systemd: available"

# ============================================================
# Phase 2: Configuration
# ============================================================

echo ""
info "===== Phase 2: Configuration ====="

read -rp "  SECRET_TOKEN ($([[ "$UI_LANG" == ja ]] && echo '必須' || echo 'required')): " INPUT_SECRET_TOKEN
INPUT_SECRET_TOKEN="${INPUT_SECRET_TOKEN#"${INPUT_SECRET_TOKEN%%[![:space:]]*}"}"
INPUT_SECRET_TOKEN="${INPUT_SECRET_TOKEN%"${INPUT_SECRET_TOKEN##*[![:space:]]}"}"
while [[ -z "$INPUT_SECRET_TOKEN" ]]; do
    warn "SECRET_TOKEN cannot be empty."
    read -rp "  SECRET_TOKEN ($([[ "$UI_LANG" == ja ]] && echo '必須' || echo 'required')): " INPUT_SECRET_TOKEN
    INPUT_SECRET_TOKEN="${INPUT_SECRET_TOKEN#"${INPUT_SECRET_TOKEN%%[![:space:]]*}"}"
    INPUT_SECRET_TOKEN="${INPUT_SECRET_TOKEN%"${INPUT_SECRET_TOKEN##*[![:space:]]}"}"
done
SECRET_TOKEN="$INPUT_SECRET_TOKEN"

# --- Port conflict check (with loop) ---
PORT_PROMPT_FIRST=true
while true; do
    read -rp "  LISTEN_PORT [8080]: " INPUT_LISTEN_PORT

    if [[ "$PORT_PROMPT_FIRST" == false && -z "$INPUT_LISTEN_PORT" ]]; then
        error "Installation cancelled."
        exit 1
    fi

    PORT_PROMPT_FIRST=false
    LISTEN_PORT="${INPUT_LISTEN_PORT:-8080}"

    PORT_HEX=$(printf '%04X' "$LISTEN_PORT" 2>/dev/null) || {
        warn "Invalid port number: $LISTEN_PORT"
        continue
    }

    PORT_IN_USE=false

    if command -v ss &>/dev/null; then
        if ss -tlnp | grep -qE ":${LISTEN_PORT}(\s|$)"; then
            PORT_IN_USE=true
        fi
    elif [[ -r /proc/net/tcp ]]; then
        if awk '{print $2}' /proc/net/tcp | grep -qi ":${PORT_HEX} 0A$"; then
            PORT_IN_USE=true
        fi
    fi

    if [[ "$PORT_IN_USE" == true ]]; then
        warn "Port ${LISTEN_PORT} is already in use. Please enter a different port."
    else
        break
    fi
done

info "Configuration:"
info "  SECRET_TOKEN = ${SECRET_TOKEN}"
info "  LISTEN_PORT  = ${LISTEN_PORT}"

# ============================================================
# Phase 3: File installation
# ============================================================

echo ""
info "===== Phase 3: Installing files ====="

# --- Check for existing installation ---
if [[ -f "$SERVICE_FILE" ]]; then
    warn "Existing service file found: ${SERVICE_FILE}"
    if ! confirm "Overwrite existing installation?"; then
        error "Installation cancelled."
        exit 1
    fi

    if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        warn "Stopping existing ${SERVICE_NAME}..."
        systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
    fi
fi

# Also check for legacy system-level service
if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    warn "Legacy system-level service detected."
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    fi
fi

# --- Install directory ---
if [[ ! -d "$INSTALL_DIR" ]]; then
    mkdir -p "$INSTALL_DIR"
    chmod 0755 "$INSTALL_DIR"
    info "Created ${INSTALL_DIR}"
else
    if [[ -f "${INSTALL_DIR}/config.json" ]]; then
        BACKUP_CONFIG="${INSTALL_DIR}/config.json.bak"
        cp -f "${INSTALL_DIR}/config.json" "$BACKUP_CONFIG"
        info "Backed up existing config.json to ${BACKUP_CONFIG}"
    fi
fi

# --- Clone repository ---
if [[ ! -f "${INSTALL_DIR}/app/main.py" ]]; then
    info "Cloning repository from ${REPO_URL}..."
    if ! git clone "$REPO_URL" "$INSTALL_DIR"; then
        error "Failed to clone repository."
        rollback
        exit 1
    fi
    CLONED=true
    info "Cloned -> ${INSTALL_DIR}"
else
    info "app/main.py already exists. Skipping clone."
fi

# --- Create the default directory before opening the folder dialog ---
mkdir -p "${INSTALL_DIR}/bin"
chmod 0755 "${INSTALL_DIR}/bin"
info "Prepared default script directory -> ${INSTALL_DIR}/bin/"

DEFAULT_SCRIPT_DIR="${INSTALL_DIR}/bin"
if _EXISTING_SCRIPT_DIR=$(read_configured_script_dir); then
    DEFAULT_SCRIPT_DIR="$_EXISTING_SCRIPT_DIR"
fi

echo ""
select_script_directory "$DEFAULT_SCRIPT_DIR"
info "  SCRIPT_DIRECTORY = ${SCRIPT_DIR}"

# --- Generate config.json (no secret_token — managed via .env) ---
python3 - "$SCRIPT_DIR" "${INSTALL_DIR}/config.json" <<'PY'
import json
import sys

with open(sys.argv[2], "w", encoding="utf-8") as config_file:
    json.dump({"script_dir": sys.argv[1]}, config_file, ensure_ascii=False, indent=4)
    config_file.write("\n")
PY
CONFIG_CREATED=true
info "Created config.json -> ${INSTALL_DIR}/config.json"

# --- Create selected directory for scripts ---
if [[ ! -d "$SCRIPT_DIR" ]]; then
    if ! mkdir -p "$SCRIPT_DIR"; then
        error "Failed to create script directory: ${SCRIPT_DIR}"
        rollback
        exit 1
    fi
    chmod 0755 "$SCRIPT_DIR"
    info "Created script directory -> ${SCRIPT_DIR}/"
else
    info "Using script directory -> ${SCRIPT_DIR}/"
fi

if [[ ! -r "$SCRIPT_DIR" || ! -w "$SCRIPT_DIR" || ! -x "$SCRIPT_DIR" ]]; then
    error "Script directory must be readable and writable: ${SCRIPT_DIR}"
    rollback
    exit 1
fi

# --- Create virtual environment ---
info "Creating Python virtual environment..."
if ! python3 -m venv "${INSTALL_DIR}/venv"; then
    error "Failed to create virtual environment."
    rollback
    exit 1
fi

if ! "${INSTALL_DIR}/venv/bin/pip" install -r "${INSTALL_DIR}/requirements.txt"; then
    error "Failed to install Python dependencies."
    rollback
    exit 1
fi
VENV_CREATED=true
info "Installed dependencies -> ${INSTALL_DIR}/venv/"

# --- Create user systemd service file ---
mkdir -p "$(dirname "$SERVICE_FILE")"

cat > "$SERVICE_FILE" <<EOF
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
EOF

SERVICE_COPIED=true
info "Installed service file -> ${SERVICE_FILE}"

# --- .env file (with GUI session info for terminal launch, Wayland preferred) ---
_DETECTED_WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}"
_DETECTED_DISPLAY="${DISPLAY:-}"
_DETECTED_XAUTH="${XAUTHORITY:-}"

# Wayland セッションの検出（優先）
# 1. 環境変数 WAYLAND_DISPLAY
# 2. /run/user/$UID/wayland-* の存在
if [[ -z "$_DETECTED_WAYLAND_DISPLAY" && -d "/run/user/${UID}" ]]; then
    for _entry in "/run/user/${UID}"/wayland-*; do
        if [[ -d "$_entry" ]]; then
            _DETECTED_WAYLAND_DISPLAY="$(basename "$_entry")"
            break
        fi
    done
fi

# X11 セッションの検出（フォールバック）
if [[ -z "$_DETECTED_WAYLAND_DISPLAY" && -z "$_DETECTED_DISPLAY" ]]; then
    _DETECTED_DISPLAY=":0"
    warn "DISPLAY not set in current environment. Defaulting to :0"
fi

# XAUTHORITY の検出（X11 / Xwayland 用）
if [[ -z "$_DETECTED_XAUTH" ]]; then
    # 1. Mutter/Xwayland: /run/user/$UID/.mutter-Xwaylandauth.*
    if [[ -d "/run/user/${UID}" ]]; then
        _MUTTER_AUTH=$(find "/run/user/${UID}" -maxdepth 1 -name '.mutter-Xwaylandauth.*' -print -quit 2>/dev/null)
        if [[ -n "$_MUTTER_AUTH" && -f "$_MUTTER_AUTH" ]]; then
            _DETECTED_XAUTH="$_MUTTER_AUTH"
        fi
    fi

    # 2. X11: ~/.Xauthority
    if [[ -z "$_DETECTED_XAUTH" && -f "${HOME}/.Xauthority" ]]; then
        _DETECTED_XAUTH="${HOME}/.Xauthority"
    fi
fi

{
    echo "SCRIPT_RUNNER_TOKEN=${SECRET_TOKEN}"
    echo "UVICORN_PORT=${LISTEN_PORT}"
    if [[ -n "$_DETECTED_WAYLAND_DISPLAY" ]]; then
        echo "WAYLAND_DISPLAY=${_DETECTED_WAYLAND_DISPLAY}"
        echo "XDG_SESSION_TYPE=wayland"
    fi
    if [[ -n "$_DETECTED_DISPLAY" ]]; then
        echo "DISPLAY=${_DETECTED_DISPLAY}"
        if [[ -z "$_DETECTED_WAYLAND_DISPLAY" ]]; then
            echo "XDG_SESSION_TYPE=x11"
        fi
    fi
    if [[ -n "$_DETECTED_XAUTH" ]]; then
        echo "XAUTHORITY=${_DETECTED_XAUTH}"
    fi
} > "${INSTALL_DIR}/.env"

ENV_CREATED=true
info "Created .env -> ${INSTALL_DIR}/.env"

if [[ -n "$_DETECTED_WAYLAND_DISPLAY" ]]; then
    info "Terminal launch: Wayland session (WAYLAND_DISPLAY=${_DETECTED_WAYLAND_DISPLAY})"
    if [[ -n "$_DETECTED_XAUTH" ]]; then
        info "  XAUTHORITY=${_DETECTED_XAUTH} (for Xwayland apps)"
    fi
elif [[ -n "$_DETECTED_DISPLAY" ]]; then
    info "Terminal launch: X11 session (DISPLAY=${_DETECTED_DISPLAY})"
    if [[ -n "$_DETECTED_XAUTH" ]]; then
        info "  XAUTHORITY=${_DETECTED_XAUTH}"
    else
        warn "  XAUTHORITY not detected — may need manual config"
    fi
else
    warn "No GUI session detected. Script execution via terminal will fail until .env is updated."
fi

# ============================================================
# Phase 4: Service activation
# ============================================================

echo ""
info "===== Phase 4: Activating service ====="

# --- Check for existing system-level installation and remove it ---
_OLD_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"
if [[ -f "$_OLD_SERVICE" ]]; then
    warn "Existing system-level service found. Removing..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$_OLD_SERVICE"
    systemctl daemon-reload 2>/dev/null || true
    info "Removed system-level service"
fi

if ! systemctl --user daemon-reload; then
    error "Failed to reload user systemd daemon."
    rollback
    exit 1
fi
info "Reloaded user systemd daemon"

if ! systemctl --user enable "$SERVICE_NAME"; then
    error "Failed to enable ${SERVICE_NAME}."
    rollback
    exit 1
fi
info "Enabled ${SERVICE_NAME} (auto-start on login)"

# Enable lingering so the service runs even when not logged in graphically
loginctl enable-linger "$(whoami)" 2>/dev/null || true

# --- Start service and verify ---
echo ""
info "Starting ${SERVICE_NAME}..."

if ! systemctl --user start "$SERVICE_NAME"; then
    error "Failed to start ${SERVICE_NAME}."
    echo ""
    warn "Installation completed but service did not start."
    warn "Check logs with:"
    warn "  journalctl --user -u ${SERVICE_NAME} -f"
    exit 1
fi

sleep 2

if systemctl --user is-active --quiet "$SERVICE_NAME"; then
    # Verify the port is listening
    PORT_OK=false
    if command -v ss &>/dev/null; then
        if ss -tlnp | grep -qE ":${LISTEN_PORT}(\s|$)"; then
            PORT_OK=true
        fi
    elif [[ -r /proc/net/tcp ]]; then
        PORT_HEX=$(printf '%04X' "$LISTEN_PORT")
        if awk '{print $2}' /proc/net/tcp | grep -qi ":${PORT_HEX} 0A$"; then
            PORT_OK=true
        fi
    fi

    echo ""
    info "============================================"
    info "Installation complete!"
    info "============================================"
    echo ""
    info "Service: ${SERVICE_NAME}"
    info "Access : http://<your-host>:${LISTEN_PORT}"
    info "Scripts: ${SCRIPT_DIR}"
    echo ""
    if [[ "$PORT_OK" == true ]]; then
        info "Port   : ${LISTEN_PORT} is listening"
    else
        warn "Port   : ${LISTEN_PORT} - could not verify (service may still be starting)"
    fi
    echo ""
    info "Status : systemctl --user status ${SERVICE_NAME}"
    info "Logs   : journalctl --user -u ${SERVICE_NAME} -f"
    info "Stop   : systemctl --user stop ${SERVICE_NAME}"
    info "Start  : systemctl --user start ${SERVICE_NAME}"
    info "============================================"
else
    error "Service failed to start."
    echo ""
    warn "Installation completed but service did not start."
    warn "Check logs with:"
    warn "  journalctl -u ${SERVICE_NAME} -f"
    exit 1
fi
