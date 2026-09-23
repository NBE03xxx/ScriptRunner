#!/usr/bin/env bash
set -euo pipefail

_LOCALE="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
case "${SCRIPT_RUNNER_LANG:-}" in
    ja|en) UI_LANG="$SCRIPT_RUNNER_LANG" ;;
    "") [[ "$_LOCALE" == ja* ]] && UI_LANG="ja" || UI_LANG="en" ;;
    *) echo "SCRIPT_RUNNER_LANG must be 'ja' or 'en'." >&2; exit 1 ;;
esac

# ============================================================
# Script Runner GUI - Uninstallation Script
# NOTE: Do NOT run with sudo. This uninstalls user-level service only.
# ============================================================

if [[ "$(id -u)" -eq 0 ]]; then
    echo ""
    if [[ "$UI_LANG" == ja ]]; then
        echo "エラー: sudo で実行しないでください。"
        echo "        次のように一般ユーザーで実行してください:"
    else
        echo "ERROR: Do not run this script with sudo."
        echo "       Run without sudo:"
    fi
    echo "         ./uninstall.sh"
    echo ""
    exit 1
fi

SERVICE_NAME="script-runner"
INSTALL_DIR="${HOME}/ScriptRunner"
BACKUP_DIR="${HOME}/ScriptRunner-backup"
DESKTOP_FILE="$HOME/.local/share/applications/com.nbe03xxx.ScriptRunner.desktop"
ICON_FILE="$HOME/.local/share/icons/hicolor/scalable/apps/script-runner.svg"

# Track deletion results
DELETED_SERVICE=false
DELETED_DROPIN=false
DELETED_PROJECT=false
HAS_DELETE_FAILURE=false
CONFIG_BACKUP_CREATED=false
ENV_BACKUP_CREATED=false
BIN_BACKUP_CREATED=false
SCRIPT_DIR="${INSTALL_DIR}/bin"
SCRIPT_DIR_EXTERNAL=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

translate() {
    local text="$1"
    [[ "$UI_LANG" == en ]] && { printf '%s' "$text"; return; }
    case "$text" in
        "===== Phase 1: Checking installation state =====") printf '===== フェーズ1: インストール状態の確認 =====' ;;
        "===== Phase 2: Backup check =====") printf '===== フェーズ2: バックアップ確認 =====' ;;
        "===== Phase 3: Checking custom scripts =====") printf '===== フェーズ3: カスタムスクリプトの確認 =====' ;;
        "===== Phase 4: Final confirmation =====") printf '===== フェーズ4: 最終確認 =====' ;;
        "===== Phase 5: Stopping service =====") printf '===== フェーズ5: サービスの停止 =====' ;;
        "===== Phase 6: Removing files =====") printf '===== フェーズ6: ファイルの削除 =====' ;;
        "===== Phase 7: Cleanup =====") printf '===== フェーズ7: クリーンアップ =====' ;;
        "Found: "*) printf '検出しました: %s' "${text#Found: }" ;;
        "Script Runner GUI does not appear to be installed.") printf 'Script Runner GUI はインストールされていないようです。' ;;
        "Incomplete installation state detected. The following resources will be removed:") printf '不完全なインストール状態を検出しました。次の項目を削除します:' ;;
        "Continue with removal?") printf '削除を続行しますか？' ;;
        "Continue with uninstallation?") printf 'アンインストールを続行しますか？' ;;
        "Uninstallation cancelled.") printf 'アンインストールをキャンセルしました。' ;;
        *" is currently active. It will be stopped during uninstallation.") printf '%s は実行中です。アンインストール時に停止します。' "${text%% is currently*}" ;;
        "Found config.json (contains your secret token):") printf 'config.json が見つかりました:' ;;
        "Found .env (contains environment variables):") printf '.env が見つかりました（環境変数を含みます）:' ;;
        "Backup this file to "*"?")
            local value="${text#Backup this file to }"
            value="${value%?}"
            printf 'このファイルを %s にバックアップしますか？' "$value"
            ;;
        "Backed up -> "*) printf 'バックアップしました -> %s' "${text#*-> }" ;;
        "Skipping backup of "*) printf '%s のバックアップを省略します' "${text#Skipping backup of }" ;;
        "Custom SSH scripts found in "*) printf 'カスタムSSHスクリプトが見つかりました: %s' "${text#* in }" ;;
        "Backup scripts to "*" before uninstallation?")
            local value="${text#Backup scripts to }"
            value="${value% before uninstallation?}"
            printf 'アンインストール前にスクリプトを %s へバックアップしますか？' "$value"
            ;;
        "External script directory will be preserved: "*) printf '外部スクリプトフォルダーは保持されます: %s' "${text#*: }" ;;
        "Scripts in "*" will be deleted with the project!")
            local value="${text#Scripts in }"
            value="${value% will be deleted with the project!}"
            printf 'プロジェクト内のスクリプトはプロジェクトと一緒に削除されます: %s' "$value"
            ;;
        "Script directory not found: "*) printf 'スクリプトフォルダーが見つかりません: %s' "${text#*: }" ;;
        "External script directory will not be removed: "*) printf '外部スクリプトフォルダーは削除しません: %s' "${text#*: }" ;;
        "Proceed with uninstallation?") printf 'アンインストールを実行しますか？' ;;
        "Stopped "*) printf '停止しました: %s' "${text#Stopped }" ;;
        "Failed to stop "*". Continuing with removal.")
            local value="${text#Failed to stop }"
            value="${value% Continued with removal.}"
            value="${value% Continuing with removal.}"
            value="${value%.}"
            printf '停止に失敗しましたが、削除を続行します: %s' "$value"
            ;;
        *" is not active. Skipping stop.") printf '%s は停止中のため、停止処理を省略します。' "${text%% is not active*}" ;;
        "Disabled "*) printf '無効化しました: %s' "${text#Disabled }" ;;
        "Failed to disable "*". Continuing with removal.")
            local value="${text#Failed to disable }"
            value="${value% Continuing with removal.}"
            value="${value%.}"
            printf '無効化に失敗しましたが、削除を続行します: %s' "$value"
            ;;
        *" is not enabled. Skipping disable.") printf '%s は無効のため、無効化処理を省略します。' "${text%% is not enabled*}" ;;
        "Removed "*) printf '削除しました: %s' "${text#Removed }" ;;
        "Failed to remove "*) printf '削除に失敗しました: %s' "${text#Failed to remove }" ;;
        *" not found. Skipping.") printf '%s は見つからないため省略します。' "${text%% not found*}" ;;
        "Uninstallation completed with errors.") printf 'エラーを伴ってアンインストールが完了しました。' ;;
        "Uninstallation complete!") printf 'アンインストールが完了しました！' ;;
        "Removal results:") printf '削除結果:' ;;
        "Backup:") printf 'バックアップ:' ;;
        "Service logs are still present in journalctl.") printf 'サービスログは journalctl に残っています。' ;;
        "To remove them, run:") printf '削除する場合は次を実行してください:' ;;
        *) printf '%s' "$text" ;;
    esac
}

info()    { echo -e "${GREEN}[INFO]${NC} $(translate "$*")"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $(translate "$*")"; }
error()   { echo -e "${RED}[ERROR]${NC} $(translate "$*")"; }

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

read_configured_script_dir() {
    local config_path="${INSTALL_DIR}/config.json"
    [[ -f "$config_path" ]] || return 1

    python3 - "$config_path" "$INSTALL_DIR" <<'PY'
import json
import os
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as config_file:
        value = json.load(config_file).get("script_dir", "bin")
    if not isinstance(value, str) or not value.strip():
        raise ValueError
    if not os.path.isabs(value):
        value = os.path.join(sys.argv[2], value)
    print(os.path.abspath(os.path.expanduser(value)))
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    sys.exit(1)
PY
}

# ============================================================
# Phase 1: Checking installation state
# ============================================================

info "===== Phase 1: Checking installation state ====="

SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
_DROPIN_DIR="$HOME/.config/systemd/user/${SERVICE_NAME}.service.d"

HAS_SERVICE=false
HAS_DROPIN=false
HAS_PROJECT=false

if [[ -f "$SERVICE_FILE" ]]; then
    HAS_SERVICE=true
    info "Found: ${SERVICE_FILE}"
fi

if [[ -d "$_DROPIN_DIR" ]]; then
    HAS_DROPIN=true
    info "Found: ${_DROPIN_DIR}/"
fi

if [[ -f "${INSTALL_DIR}/app/main.py" ]]; then
    HAS_PROJECT=true
    info "Found: ${INSTALL_DIR}/app/main.py"
fi

# All not present -> nothing to uninstall
if [[ "$HAS_SERVICE" == false && "$HAS_DROPIN" == false && "$HAS_PROJECT" == false ]]; then
    echo ""
    warn "Script Runner GUI does not appear to be installed."
    exit 0
fi

if _CONFIGURED_SCRIPT_DIR=$(read_configured_script_dir); then
    SCRIPT_DIR="$_CONFIGURED_SCRIPT_DIR"
fi

case "$SCRIPT_DIR" in
    "$INSTALL_DIR"|"$INSTALL_DIR"/*) SCRIPT_DIR_EXTERNAL=false ;;
    *) SCRIPT_DIR_EXTERNAL=true ;;
esac

# Partial state detected（drop-inは任意なので判定数に含めない）
if [[ "$HAS_SERVICE" != "$HAS_PROJECT" ]]; then
    echo ""
    warn "Incomplete installation state detected. The following resources will be removed:"
    if [[ "$HAS_SERVICE" == true ]]; then
        warn "  - ${SERVICE_FILE}"
    fi
    if [[ "$HAS_DROPIN" == true ]]; then
        warn "  - ${_DROPIN_DIR}/"
    fi
    if [[ "$HAS_PROJECT" == true ]]; then
        warn "  - ${INSTALL_DIR}/app/"
    fi
    echo ""
    if ! confirm "Continue with removal?"; then
        error "Uninstallation cancelled."
        exit 0
    fi
fi

# --- Service running check ---
if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo ""
    warn "${SERVICE_NAME} is currently active. It will be stopped during uninstallation."
    if ! confirm "Continue with uninstallation?"; then
        error "Uninstallation cancelled."
        exit 0
    fi
fi

# ============================================================
# Phase 2: Backup check
# ============================================================

echo ""
info "===== Phase 2: Backup check ====="

if [[ -f "${INSTALL_DIR}/config.json" ]]; then
    echo ""
    info "Found config.json:"
    if confirm "Backup this file to ${BACKUP_DIR}/config.json?"; then
        mkdir -p "$BACKUP_DIR"
        cp -f "${INSTALL_DIR}/config.json" "${BACKUP_DIR}/config.json"
        info "Backed up -> ${BACKUP_DIR}/config.json"
        CONFIG_BACKUP_CREATED=true
    else
        info "Skipping backup of config.json"
    fi
fi

if [[ -f "${INSTALL_DIR}/.env" ]]; then
    echo ""
    info "Found .env (contains environment variables):"
    if confirm "Backup this file to ${BACKUP_DIR}/.env?"; then
        mkdir -p "$BACKUP_DIR"
        cp -f "${INSTALL_DIR}/.env" "${BACKUP_DIR}/.env"
        info "Backed up -> ${BACKUP_DIR}/.env"
        ENV_BACKUP_CREATED=true
    else
        info "Skipping backup of .env"
    fi
fi

# ============================================================
# Phase 3: Checking custom scripts
# ============================================================

echo ""
info "===== Phase 3: Checking custom scripts ====="

if [[ -d "$SCRIPT_DIR" ]]; then
    _BIN_FILES=()
    while IFS= read -r -d '' file; do
        _BIN_FILES+=("$(basename -- "$file")")
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -name '*.sh' -print0)

    if [[ ${#_BIN_FILES[@]} -gt 0 ]]; then
        warn "Custom SSH scripts found in ${SCRIPT_DIR}/:"
        for f in "${_BIN_FILES[@]}"; do
            warn "  - ${f}"
        done
        echo ""
        _SCRIPT_BACKUP_DIR="${BACKUP_DIR}/scripts"
        if [[ -e "$_SCRIPT_BACKUP_DIR" ]]; then
            _SCRIPT_BACKUP_DIR="${BACKUP_DIR}/scripts-$(date '+%Y%m%d-%H%M%S')"
        fi
        if confirm "Backup scripts to ${_SCRIPT_BACKUP_DIR}/ before uninstallation?"; then
            mkdir -p "$BACKUP_DIR"
            cp -a "$SCRIPT_DIR" "$_SCRIPT_BACKUP_DIR"
            info "Backed up -> ${_SCRIPT_BACKUP_DIR}/"
            SCRIPT_BACKUP_DIR="$_SCRIPT_BACKUP_DIR"
            BIN_BACKUP_CREATED=true
        else
            if [[ "$SCRIPT_DIR_EXTERNAL" == true ]]; then
                info "External script directory will be preserved: ${SCRIPT_DIR}/"
            else
                warn "Scripts in ${SCRIPT_DIR}/ will be deleted with the project!"
            fi
        fi
    fi
else
    info "Script directory not found: ${SCRIPT_DIR}/"
fi


if [[ "$SCRIPT_DIR_EXTERNAL" == true ]]; then
    info "External script directory will not be removed: ${SCRIPT_DIR}/"
fi

# ============================================================
# Phase 4: Final confirmation
# ============================================================

echo ""
info "===== Phase 4: Final confirmation ====="
echo ""
if [[ "$UI_LANG" == ja ]]; then
    echo "次の項目を削除します:"
else
    echo "The following resources will be removed:"
fi
echo ""

if [[ "$HAS_SERVICE" == true ]]; then
    echo "  [ ] ${SERVICE_FILE}"
fi
if [[ "$HAS_DROPIN" == true ]]; then
    echo "  [ ] ${_DROPIN_DIR}/"
fi
if [[ "$HAS_PROJECT" == true ]]; then
    if [[ "$UI_LANG" == ja ]]; then
        echo "  [ ] ${INSTALL_DIR}/（プロジェクトディレクトリ全体）"
    else
        echo "  [ ] ${INSTALL_DIR}/ (entire project directory)"
    fi
fi

echo ""
if ! confirm "Proceed with uninstallation?"; then
    error "Uninstallation cancelled."
    exit 0
fi

# ============================================================
# Phase 5: Stopping service
# ============================================================

echo ""
info "===== Phase 5: Stopping service ====="

if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    if systemctl --user stop "$SERVICE_NAME" 2>/dev/null; then
        info "Stopped ${SERVICE_NAME}"
    else
        error "Failed to stop ${SERVICE_NAME}. Files were not removed."
        exit 1
    fi
else
    info "${SERVICE_NAME} is not active. Skipping stop."
fi

if systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    if systemctl --user disable "$SERVICE_NAME" 2>/dev/null; then
        info "Disabled ${SERVICE_NAME}"
    else
        error "Failed to disable ${SERVICE_NAME}. Files were not removed."
        exit 1
    fi
else
    info "${SERVICE_NAME} is not enabled. Skipping disable."
fi

# ============================================================
# Phase 6: Removing files
# ============================================================

echo ""
info "===== Phase 6: Removing files ====="

# --- Service file ---
if [[ -f "$SERVICE_FILE" ]]; then
    if rm -f "$SERVICE_FILE"; then
        DELETED_SERVICE=true
        info "Removed ${SERVICE_FILE}"
    else
        error "Failed to remove ${SERVICE_FILE}"
        HAS_DELETE_FAILURE=true
    fi
else
    info "${SERVICE_FILE} not found. Skipping."
fi

# --- drop-in directory ---
if [[ -d "$_DROPIN_DIR" ]]; then
    if rm -rf "$_DROPIN_DIR"; then
        DELETED_DROPIN=true
        info "Removed ${_DROPIN_DIR}/"
    else
        error "Failed to remove ${_DROPIN_DIR}/"
        HAS_DELETE_FAILURE=true
    fi
else
    info "${_DROPIN_DIR}/ not found. Skipping."
fi

# --- desktop entry and icon ---
if [[ -f "$DESKTOP_FILE" ]]; then
    rm -f "$DESKTOP_FILE" && info "Removed ${DESKTOP_FILE}" || HAS_DELETE_FAILURE=true
fi
if [[ -f "$ICON_FILE" ]]; then
    rm -f "$ICON_FILE" && info "Removed ${ICON_FILE}" || HAS_DELETE_FAILURE=true
fi
command -v update-desktop-database &>/dev/null && update-desktop-database "$(dirname "$DESKTOP_FILE")" || true
command -v gtk-update-icon-cache &>/dev/null && gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

# --- runtime connection information ---
_RUNTIME_BASE="${XDG_RUNTIME_DIR:-/run/user/${UID}}"
_RUNTIME_DIR="${_RUNTIME_BASE}/script-runner"
if [[ -d "$_RUNTIME_DIR" && ! -L "$_RUNTIME_DIR" && -O "$_RUNTIME_DIR" ]]; then
    rm -f "${_RUNTIME_DIR}/connection.json"
    rmdir "$_RUNTIME_DIR" 2>/dev/null || true
fi

# --- Install directory (including venv) ---
if [[ -d "$INSTALL_DIR" ]]; then
    if rm -rf "$INSTALL_DIR"; then
        DELETED_PROJECT=true
        info "Removed ${INSTALL_DIR}/"
    else
        error "Failed to remove ${INSTALL_DIR}/"
        HAS_DELETE_FAILURE=true
    fi
else
    info "${INSTALL_DIR} not found. Skipping."
fi

# ============================================================
# Phase 7: Cleanup
# ============================================================

echo ""
info "===== Phase 7: Cleanup ====="

systemctl --user daemon-reload 2>/dev/null && info "Reloaded user systemd daemon" || true

# --- Final message ---
echo ""

if [[ "$HAS_DELETE_FAILURE" == true ]]; then
    warn "============================================"
    warn "Uninstallation completed with errors."
    warn "============================================"
else
    info "============================================"
    info "Uninstallation complete!"
    info "============================================"
fi

echo ""
info "Removal results:"

if [[ "$HAS_SERVICE" == true ]]; then
    if [[ "$DELETED_SERVICE" == true ]]; then
        echo -e "  ${GREEN}✓${NC} ${SERVICE_FILE}"
    else
        echo -e "  ${RED}✗${NC} ${SERVICE_FILE} ($([[ "$UI_LANG" == ja ]] && echo '失敗' || echo 'failed'))"
    fi
fi

if [[ "$HAS_DROPIN" == true ]]; then
    if [[ "$DELETED_DROPIN" == true ]]; then
        echo -e "  ${GREEN}✓${NC} ${_DROPIN_DIR}/"
    else
        echo -e "  ${RED}✗${NC} ${_DROPIN_DIR}/ ($([[ "$UI_LANG" == ja ]] && echo '失敗' || echo 'failed'))"
    fi
fi

if [[ "$HAS_PROJECT" == true ]]; then
    if [[ "$DELETED_PROJECT" == true ]]; then
        echo -e "  ${GREEN}✓${NC} ${INSTALL_DIR}/"
    else
        echo -e "  ${RED}✗${NC} ${INSTALL_DIR}/ ($([[ "$UI_LANG" == ja ]] && echo '失敗' || echo 'failed'))"
    fi
fi

HAS_ANY_BACKUP=false
if [[ "$CONFIG_BACKUP_CREATED" == true || "$ENV_BACKUP_CREATED" == true || "$BIN_BACKUP_CREATED" == true ]]; then
    HAS_ANY_BACKUP=true
fi

if [[ "$HAS_ANY_BACKUP" == true ]]; then
    echo ""
    info "Backup:"
    if [[ "$CONFIG_BACKUP_CREATED" == true ]]; then
        echo -e "  ~ ${BACKUP_DIR}/config.json"
    fi
    if [[ "$ENV_BACKUP_CREATED" == true ]]; then
        echo -e "  ~ ${BACKUP_DIR}/.env"
    fi
    if [[ "$BIN_BACKUP_CREATED" == true ]]; then
        echo -e "  ~ ${SCRIPT_BACKUP_DIR}/"
    fi
fi

echo ""
warn "Service logs are still present in journalctl."
warn "To remove them, run:"
warn "  journalctl --user --rotate && journalctl --user --vacuum-time=1s"

if [[ "$HAS_DELETE_FAILURE" == true ]]; then
    exit 1
fi

exit 0
