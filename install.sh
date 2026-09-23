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

INSTALLER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL_DIR="${SCRIPT_RUNNER_INSTALL_DIR:-${HOME}/ScriptRunner}"
SOURCE_DIR="${SCRIPT_RUNNER_SOURCE_DIR:-$INSTALLER_DIR}"
SERVICE_NAME="script-runner"
SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
DESKTOP_FILE="$HOME/.local/share/applications/com.nbe03xxx.ScriptRunner.desktop"
ICON_FILE="$HOME/.local/share/icons/hicolor/scalable/apps/script-runner.svg"

# Track what we've installed for rollback
VENV_CREATED=false
CONFIG_CREATED=false
SERVICE_COPIED=false
DESKTOP_CREATED=false
ICON_CREATED=false
INSTALL_DIR_CREATED=false
ROLLBACK_DIR=""
ROLLBACK_READY=false
ROLLBACK_DONE=false
INSTALL_SUCCEEDED=false
HAD_CONFIG=false
HAD_VENV=false
HAD_SERVICE=false
HAD_DESKTOP=false
HAD_ICON=false
WAS_SERVICE_ACTIVE=false
WAS_SERVICE_ENABLED=false

MANAGED_PATHS=(
    app requirements.txt README.md DOCUMENTS.md install.sh uninstall.sh
    DESKTOP_APP_PLAN.md tests config.example.json LICENSE
)

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
    [[ "$ROLLBACK_READY" == true && "$ROLLBACK_DONE" == false ]] || return 0
    ROLLBACK_DONE=true
    echo ""
    warn "Rolling back changes..."

    systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true

    if [[ "$INSTALL_DIR_CREATED" == true ]]; then
        rm -rf "$INSTALL_DIR" && info "Removed cloned directory" || true
    else
        for managed_path in "${MANAGED_PATHS[@]}"; do
            rm -rf -- "${INSTALL_DIR:?}/${managed_path}" || true
            if [[ -e "${ROLLBACK_DIR}/install/${managed_path}" || -L "${ROLLBACK_DIR}/install/${managed_path}" ]]; then
                mkdir -p -- "$(dirname -- "${INSTALL_DIR}/${managed_path}")"
                cp -a -- "${ROLLBACK_DIR}/install/${managed_path}" "${INSTALL_DIR}/${managed_path}" || true
            fi
        done

        rm -rf -- "${INSTALL_DIR:?}/venv" || true
        if [[ "$HAD_VENV" == true && -d "${ROLLBACK_DIR}/venv" ]]; then
            mv -- "${ROLLBACK_DIR}/venv" "${INSTALL_DIR}/venv" || true
        fi

        if [[ "$HAD_CONFIG" == true ]]; then
            cp -a -- "${ROLLBACK_DIR}/config.json" "${INSTALL_DIR}/config.json" || true
        else
            rm -f -- "${INSTALL_DIR}/config.json" || true
        fi
    fi

    rm -f -- "$SERVICE_FILE" "$DESKTOP_FILE" "$ICON_FILE" || true
    [[ "$HAD_SERVICE" == true ]] && cp -a -- "${ROLLBACK_DIR}/service" "$SERVICE_FILE" || true
    [[ "$HAD_DESKTOP" == true ]] && cp -a -- "${ROLLBACK_DIR}/desktop" "$DESKTOP_FILE" || true
    [[ "$HAD_ICON" == true ]] && cp -a -- "${ROLLBACK_DIR}/icon" "$ICON_FILE" || true

    systemctl --user daemon-reload 2>/dev/null || true
    if [[ "$WAS_SERVICE_ENABLED" == true ]]; then
        systemctl --user enable "$SERVICE_NAME" 2>/dev/null || true
    else
        systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
    fi
    [[ "$WAS_SERVICE_ACTIVE" == true ]] && systemctl --user start "$SERVICE_NAME" 2>/dev/null || true

    rm -rf -- "$ROLLBACK_DIR" || true
}

finish_install() {
    INSTALL_SUCCEEDED=true
    ROLLBACK_READY=false
    [[ -n "$ROLLBACK_DIR" ]] && rm -rf -- "$ROLLBACK_DIR"
}

on_exit() {
    local status=$?
    if [[ $status -ne 0 && "$INSTALL_SUCCEEDED" == false ]]; then
        rollback
    fi
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

prepare_rollback() {
    ROLLBACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/script-runner-install.XXXXXX")"
    mkdir -p "${ROLLBACK_DIR}/install"

    if [[ -d "$INSTALL_DIR" ]]; then
        for managed_path in "${MANAGED_PATHS[@]}"; do
            if [[ -e "${INSTALL_DIR}/${managed_path}" || -L "${INSTALL_DIR}/${managed_path}" ]]; then
                mkdir -p -- "$(dirname -- "${ROLLBACK_DIR}/install/${managed_path}")"
                cp -a -- "${INSTALL_DIR}/${managed_path}" "${ROLLBACK_DIR}/install/${managed_path}"
            fi
        done
        if [[ -f "${INSTALL_DIR}/config.json" ]]; then
            HAD_CONFIG=true
            cp -a -- "${INSTALL_DIR}/config.json" "${ROLLBACK_DIR}/config.json"
        fi
        if [[ -d "${INSTALL_DIR}/venv" ]]; then
            HAD_VENV=true
        fi
    fi

    if [[ -f "$SERVICE_FILE" ]]; then
        HAD_SERVICE=true
        cp -a -- "$SERVICE_FILE" "${ROLLBACK_DIR}/service"
    fi
    if [[ -f "$DESKTOP_FILE" ]]; then
        HAD_DESKTOP=true
        cp -a -- "$DESKTOP_FILE" "${ROLLBACK_DIR}/desktop"
    fi
    if [[ -f "$ICON_FILE" ]]; then
        HAD_ICON=true
        cp -a -- "$ICON_FILE" "${ROLLBACK_DIR}/icon"
    fi
    systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null && WAS_SERVICE_ACTIVE=true
    systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && WAS_SERVICE_ENABLED=true
    ROLLBACK_READY=true
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

verify_service_connection() {
    local connection_file="$1"
    python3 - "$connection_file" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request
import http.cookiejar

try:
    with open(sys.argv[1], encoding="utf-8") as connection_stream:
        connection = json.load(connection_stream)
    if connection.get("host") != "127.0.0.1":
        raise ValueError("unexpected host")
    port = connection.get("port")
    token = connection.get("token")
    pid = connection.get("pid")
    instance_id = connection.get("instance_id")
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise ValueError("invalid port")
    if not isinstance(token, str) or len(token) < 32:
        raise ValueError("invalid token")
    if not isinstance(pid, int) or pid <= 0:
        raise ValueError("invalid pid")
    if not isinstance(instance_id, str) or not instance_id:
        raise ValueError("invalid instance id")
    os.kill(pid, 0)
    url = f"http://127.0.0.1:{port}/desktop/bootstrap/{token}"
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
    )
    with opener.open(url, timeout=1) as response:
        if response.status != 200:
            raise ValueError(f"unexpected HTTP status: {response.status}")
    with opener.open(f"http://127.0.0.1:{port}/api/health", timeout=1) as response:
        if json.load(response).get("instance_id") != instance_id:
            raise ValueError("service instance id mismatch")
except (OSError, ValueError, TypeError, json.JSONDecodeError, urllib.error.URLError):
    sys.exit(1)
PY
}

wait_for_service_connection() {
    local connection_file="$1"
    local attempt
    for attempt in {1..50}; do
        if [[ -r "$connection_file" ]] && verify_service_connection "$connection_file"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
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

if [[ ! -f "${SOURCE_DIR}/app/main.py" || ! -f "${SOURCE_DIR}/requirements.txt" ]]; then
    error "Application source files were not found: ${SOURCE_DIR}"
    exit 1
fi

if ! command -v systemctl &>/dev/null; then
    error "systemd is not available."
    exit 1
fi
info "systemd: available"

if [[ ! -r /etc/os-release ]] || ! grep -q '^ID=ubuntu$' /etc/os-release || ! grep -q '^VERSION_ID="26.04"$' /etc/os-release; then
    error "This application supports Ubuntu 26.04 only."
    exit 1
fi
info "Ubuntu 26.04: available"

if ! python3 - <<'PY'
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("WebKit", "6.0")
from gi.repository import Gtk, WebKit
PY
then
    error "GTK4 / WebKitGTK 6.0 Python bindings are not available."
    warn "Install them first:"
    warn "  sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-4.0 gir1.2-webkit-6.0 libwebkitgtk-6.0-4"
    exit 1
fi
info "GTK4 / WebKitGTK 6.0: available"

if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    error "Legacy system-level service detected."
    warn "Remove the old system service before installing the user service:"
    warn "  sudo systemctl disable --now ${SERVICE_NAME}"
    warn "  sudo rm /etc/systemd/system/${SERVICE_NAME}.service"
    warn "  sudo systemctl daemon-reload"
    exit 1
fi

for target in "$INSTALL_DIR" "$SERVICE_FILE" "$DESKTOP_FILE" "$ICON_FILE"; do
    if [[ -L "$target" ]]; then
        error "Symbolic-link installation target is not supported: ${target}"
        exit 1
    fi
done

# ============================================================
# Phase 2: Configuration
# ============================================================

echo ""
info "===== Phase 2: Configuration ====="
info "The service will select a private loopback port automatically."
info "Authentication credentials will be generated for each service start."

# ============================================================
# Phase 3: File installation
# ============================================================

echo ""
info "===== Phase 3: Installing files ====="

# --- Check for existing installation ---
if [[ -f "$SERVICE_FILE" || -f "${INSTALL_DIR}/app/main.py" ]]; then
    warn "Existing service file found: ${SERVICE_FILE}"
    if ! confirm "Overwrite existing installation?"; then
        error "Installation cancelled."
        exit 1
    fi
fi

DEFAULT_SCRIPT_DIR="${INSTALL_DIR}/bin"
if _EXISTING_SCRIPT_DIR=$(read_configured_script_dir); then
    DEFAULT_SCRIPT_DIR="$_EXISTING_SCRIPT_DIR"
fi

echo ""
select_script_directory "$DEFAULT_SCRIPT_DIR"
info "  SCRIPT_DIRECTORY = ${SCRIPT_DIR}"

prepare_rollback

if [[ "$WAS_SERVICE_ACTIVE" == true ]]; then
    warn "Stopping existing ${SERVICE_NAME}..."
    systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
fi

# --- Install directory ---
if [[ ! -d "$INSTALL_DIR" ]]; then
    mkdir -p "$INSTALL_DIR"
    chmod 0755 "$INSTALL_DIR"
    INSTALL_DIR_CREATED=true
    info "Created ${INSTALL_DIR}"
fi

# --- Install or update application files ---
if [[ "$(cd -- "$SOURCE_DIR" && pwd -P)" != "$(cd -- "$INSTALL_DIR" && pwd -P)" ]]; then
    for managed_path in "${MANAGED_PATHS[@]}"; do
        [[ -e "${SOURCE_DIR}/${managed_path}" || -L "${SOURCE_DIR}/${managed_path}" ]] || continue
        rm -rf -- "${INSTALL_DIR:?}/${managed_path}"
        cp -a -- "${SOURCE_DIR}/${managed_path}" "${INSTALL_DIR}/${managed_path}"
    done
    info "Installed application files from ${SOURCE_DIR}"
else
    info "Application files are already in ${INSTALL_DIR}"
fi

# --- Create the default directory before opening the folder dialog ---
mkdir -p "${INSTALL_DIR}/bin"
chmod 0755 "${INSTALL_DIR}/bin"
info "Prepared default script directory -> ${INSTALL_DIR}/bin/"

# --- Generate config.json ---
python3 - "$SCRIPT_DIR" "${INSTALL_DIR}/config.json" <<'PY'
import json
import sys

try:
    with open(sys.argv[2], encoding="utf-8") as config_file:
        config = json.load(config_file)
    if not isinstance(config, dict):
        raise ValueError("config.json must contain an object")
except FileNotFoundError:
    config = {}

config["script_dir"] = sys.argv[1]
with open(sys.argv[2], "w", encoding="utf-8") as config_file:
    json.dump(config, config_file, ensure_ascii=False, indent=4)
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
if [[ "$HAD_VENV" == true && -d "${INSTALL_DIR}/venv" ]]; then
    mv -- "${INSTALL_DIR}/venv" "${ROLLBACK_DIR}/venv"
fi
if ! python3 -m venv --system-site-packages "${INSTALL_DIR}/venv"; then
    error "Failed to create virtual environment."
    exit 1
fi
VENV_CREATED=true

if ! "${INSTALL_DIR}/venv/bin/pip" install -r "${INSTALL_DIR}/requirements.txt"; then
    error "Failed to install Python dependencies."
    exit 1
fi
info "Installed dependencies -> ${INSTALL_DIR}/venv/"

# --- Create user systemd service file ---
mkdir -p "$(dirname "$SERVICE_FILE")"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Script Runner backend service
After=default.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/python -m app.service
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

# --- Desktop entry and icon ---
mkdir -p "$(dirname "$DESKTOP_FILE")" "$(dirname "$ICON_FILE")"
cp -f "${INSTALL_DIR}/app/static/favicon.svg" "$ICON_FILE"
ICON_CREATED=true

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Script Runner
Comment=シェルスクリプトを管理・実行します
Exec=${INSTALL_DIR}/venv/bin/python -m app.desktop
Path=${INSTALL_DIR}
Icon=script-runner
Terminal=false
Categories=Utility;System;
StartupNotify=true
StartupWMClass=com.nbe03xxx.ScriptRunner
EOF
chmod 0644 "$DESKTOP_FILE" "$ICON_FILE"
DESKTOP_CREATED=true
command -v update-desktop-database &>/dev/null && update-desktop-database "$(dirname "$DESKTOP_FILE")" || true
command -v gtk-update-icon-cache &>/dev/null && gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
info "Installed desktop entry -> ${DESKTOP_FILE}"

# ============================================================
# Phase 4: Service activation
# ============================================================

echo ""
info "===== Phase 4: Activating service ====="

if ! systemctl --user daemon-reload; then
    error "Failed to reload user systemd daemon."
    exit 1
fi
info "Reloaded user systemd daemon"

if ! systemctl --user enable "$SERVICE_NAME"; then
    error "Failed to enable ${SERVICE_NAME}."
    exit 1
fi
info "Enabled ${SERVICE_NAME} (auto-start on login)"

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

if systemctl --user is-active --quiet "$SERVICE_NAME"; then
    RUNTIME_BASE="${XDG_RUNTIME_DIR:-/run/user/${UID}}"
    CONNECTION_FILE="${RUNTIME_BASE}/script-runner/connection.json"

    if ! wait_for_service_connection "$CONNECTION_FILE"; then
        error "Service connection verification failed: ${CONNECTION_FILE}"
        warn "Check logs with:"
        warn "  journalctl --user -u ${SERVICE_NAME} -f"
        exit 1
    fi

    echo ""
    info "============================================"
    info "Installation complete!"
    info "============================================"
    echo ""
    info "Service: ${SERVICE_NAME}"
    info "Application: Script Runner (application menu)"
    info "Scripts: ${SCRIPT_DIR}"
    echo ""
    info "Connection: ${CONNECTION_FILE}"
    echo ""
    info "Status : systemctl --user status ${SERVICE_NAME}"
    info "Logs   : journalctl --user -u ${SERVICE_NAME} -f"
    info "Stop   : systemctl --user stop ${SERVICE_NAME}"
    info "Start  : systemctl --user start ${SERVICE_NAME}"
    info "============================================"
    finish_install
else
    error "Service failed to start."
    echo ""
    warn "Installation completed but service did not start."
    warn "Check logs with:"
    warn "  journalctl --user -u ${SERVICE_NAME} -f"
    exit 1
fi
