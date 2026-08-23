import asyncio
import json
import os
import re
import shutil
import socket
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from typing import List, Optional, Tuple

app = FastAPI()

# Directory settings - read from config file
CONFIG_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "config.json")
def load_config(path: str) -> dict:
    """設定ファイルを読み込む。相対パスは設定ファイルのあるディレクトリを基準に解決する。"""
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

CONFIG = load_config(CONFIG_PATH)
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT_DIR = os.path.join(PROJECT_DIR, CONFIG.get("script_dir", "bin"))
STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
SECRET_TOKEN = os.environ.get("SCRIPT_RUNNER_TOKEN") or CONFIG.get("secret_token")

# Load execution whitelist from white_list.txt in project root.
# Rules:
#   - File absent         -> all scripts allowed
#   - Empty file          -> all scripts allowed
#   - Contains "none"     -> no scripts allowed (all blocked)
#   - Otherwise           -> only listed script names are allowed
# Lines starting with '#' are comments and ignored.
_EXEC_WHITELIST: Optional[List[str]] = None

_WHITELIST_PATH = os.path.join(PROJECT_DIR, "white_list.txt")
if os.path.isfile(_WHITELIST_PATH):
    _raw_lines = []
    try:
        with open(_WHITELIST_PATH, "r", encoding="utf-8") as _f:
            _raw_lines = [
                line.strip()
                for line in _f
                if (line.strip() and not line.startswith("#"))
            ]
    except Exception:
        _raw_lines = []

    if not _raw_lines:
        _EXEC_WHITELIST = None  # empty -> all allowed
    elif len(_raw_lines) == 1 and _raw_lines[0].lower() == "none":
        _EXEC_WHITELIST = []     # none -> all blocked
    else:
        _EXEC_WHITELIST = _raw_lines

# Terminal execution doesn't need result polling anymore.

# Mount static directory to serve CSS, JS, etc.
if os.path.exists(STATIC_DIR):
    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.middleware("http")
async def authenticate(request: Request, call_next):
    """API エンドポイントに対してトークン認証を要求する。"""
    # static ファイルとトップページ、トークン状態エンドポイントのみスキップ
    if request.url.path.startswith("/static/") or \
       request.url.path == "/" or \
       request.url.path == "/api/token-required":
        return await call_next(request)

    token = request.headers.get("X-Secret-Token")
    if SECRET_TOKEN and token != SECRET_TOKEN:
        hint = ""
        if token is None:
            hint = "トークンヘッダーが送信されていません"
        elif len(token) != len(SECRET_TOKEN):
            hint = f"トークンの長さが異なります (送られてきた: {len(token)}, 期待: {len(SECRET_TOKEN)})"
        else:
            hint = "トークンが一致しません"
        return JSONResponse(status_code=401, content={"detail": f"認証に失敗しました: {hint}"})

    response = await call_next(request)
    return response


@app.get("/api/token-required")
async def is_token_required():
    """トークン認証が有効かどうかを返す（未認証で呼び出し可能）。"""
    src = "none"
    env_tok = os.environ.get("SCRIPT_RUNNER_TOKEN")
    cfg_tok = CONFIG.get("secret_token")
    if env_tok:
        src = "env"
    elif cfg_tok:
        src = "config.json"
    return {
        "required": bool(SECRET_TOKEN),
        "_debug_source": src,
        "_debug_length": len(SECRET_TOKEN) if SECRET_TOKEN else 0,
    }

_RESOLVED_SCRIPT_DIR = os.path.realpath(SCRIPT_DIR)


def resolve_safe_path(filename: str) -> str:
    """SCRIPT_DIR 内に限定された安全なパスを返す。"""
    path = os.path.realpath(os.path.join(SCRIPT_DIR, filename))
    if not path.startswith(_RESOLVED_SCRIPT_DIR + os.sep) and path != _RESOLVED_SCRIPT_DIR:
        raise HTTPException(status_code=403, detail="許可されていないパスです")
    return path

def _is_executable(name: str) -> bool:
    if _EXEC_WHITELIST is None:
        return True
    return name in _EXEC_WHITELIST


class ScriptInfo(BaseModel):
    name: str
    path: str
    host: str
    mtime: float
    group: str = ""
    tags: List[str] = Field(default_factory=list)
    executable: bool = True


class ScriptContent(BaseModel):
    """スクリプトの保存内容。"""

    content: str


def _extract_host(content: str) -> str:
    """スクリプト内容から ssh 接続先ホストを抽出する。コメント行は対象外とする。"""
    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # ssh が行頭にある場合だけでなく、
        # `ptyxis --new-window -- ssh user@host` のように端末から起動する形式も扱う。
        match = re.search(
            r'(?<![-\w])ssh\s+'
            r'(?:-[a-zA-Z]+(?:\s+\S+)?\s+)*'
            r'(?:[\w.-]+@)?'
            r'([\d.]+|[a-zA-Z0-9][-a-zA-Z0-9.]*)',
            stripped,
        )
        if match:
            return match.group(1)
    return "Unknown"


def _extract_metadata(content: str, max_lines: int = 30) -> Tuple[str, List[str]]:
    """スクリプト冒頭のコメントから Group / Tag を抽出する。"""
    group = ""
    tags: List[str] = []
    seen_tags = set()
    for line in content.splitlines()[:max_lines]:
        group_match = re.match(r'^\s*#\s*group\s*:\s*(.*?)\s*$', line, re.IGNORECASE)
        if group_match and not group:
            value = group_match.group(1).strip()
            if value:
                group = value
            continue

        tag_match = re.match(r'^\s*#\s*tag\s*:\s*(.*?)\s*$', line, re.IGNORECASE)
        if tag_match:
            value = tag_match.group(1).strip()
            if value and value not in seen_tags:
                tags.append(value)
                seen_tags.add(value)
    return group, tags


def parse_script_info(file_path: str) -> ScriptInfo:
    """スクリプトファイルから一覧表示用の情報を抽出する。"""
    name = os.path.basename(file_path)
    host = "Unknown"
    group = ""
    tags: List[str] = []
    mtime = 0.0
    try:
        if os.path.exists(file_path):
            mtime = os.path.getmtime(file_path)
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read()
                host = _extract_host(content)
                group, tags = _extract_metadata(content)
    except Exception as e:
        print(f"Error parsing {name}: {e}")
    return ScriptInfo(
        name=name, path=file_path, host=host,
        mtime=mtime, group=group, tags=tags,
        executable=_is_executable(name),
    )

# Natural sort key that correctly orders filenames containing IP-like numeric parts.
def natural_key_path(path: str) -> Tuple:
    """Return a sortable key that treats numeric parts as integers."""
    subparts = re.findall(r'\d+|\D+', path)
    key: List[Tuple] = []
    for sp in subparts:
        if sp.isdigit():
            key.append((0, int(sp), ''))
        else:
            key.append((1, 0, sp))
    return tuple(key)

@app.get("/api/scripts", response_model=List[ScriptInfo])
async def list_scripts():
    if not os.path.exists(SCRIPT_DIR):
        raise HTTPException(status_code=404, detail="スクリプトディレクトリが見つかりません。config.json を確認してください。")
    
    files = [f for f in os.listdir(SCRIPT_DIR) if f.endswith(".sh")]
    sorted_files = sorted(files, key=natural_key_path)
    
    return [parse_script_info(os.path.join(SCRIPT_DIR, f)) 
            for f in sorted_files]

@app.get("/api/read/{filename}")
async def read_script(filename: str):
    path = resolve_safe_path(filename)
    if not os.path.exists(path): raise HTTPException(status_code=404)
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    return {"content": content}

@app.post("/api/save/{filename}")
async def save_script(filename: str, data: dict):
    if not filename.endswith(".sh"):
        raise HTTPException(status_code=400, detail="拡張子 .sh のファイルのみ保存可能です")
    path = resolve_safe_path(filename)
    if not os.path.exists(path): raise HTTPException(status_code=404)
    content = data.get("content", "")
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return {"message": "Saved successfully"}


def validate_new_script_filename(filename: str) -> None:
    """新規作成に利用できる単一の .sh ファイル名か検証する。"""
    if not filename or filename != filename.strip():
        raise HTTPException(status_code=400, detail="ファイル名の前後に空白は使用できません")
    if filename in (".", "..") or filename == ".sh":
        raise HTTPException(status_code=400, detail="有効なファイル名を入力してください")
    if "/" in filename or "\\" in filename:
        raise HTTPException(status_code=400, detail="ファイル名にパス区切り文字は使用できません")
    if any(ord(char) < 32 or ord(char) == 127 for char in filename):
        raise HTTPException(status_code=400, detail="ファイル名に制御文字は使用できません")
    if not filename.endswith(".sh"):
        raise HTTPException(status_code=400, detail="拡張子 .sh のファイル名を入力してください")


@app.post("/api/create/{filename}", status_code=201)
async def create_script(filename: str, data: ScriptContent):
    """既存ファイルを上書きせず、新しいシェルスクリプトを作成する。"""
    validate_new_script_filename(filename)
    if not os.path.exists(SCRIPT_DIR):
        raise HTTPException(status_code=404, detail="スクリプトディレクトリが見つかりません")
    if not os.path.isdir(SCRIPT_DIR):
        raise HTTPException(status_code=400, detail="スクリプト保存先がディレクトリではありません")

    path = resolve_safe_path(filename)
    created = False
    try:
        with open(path, "x", encoding="utf-8") as f:
            created = True
            f.write(data.content)
    except FileExistsError:
        raise HTTPException(status_code=409, detail="同じ名前のスクリプトが既に存在します")
    except OSError:
        if created:
            try:
                os.unlink(path)
            except OSError:
                pass
        raise HTTPException(status_code=500, detail="スクリプトを作成できませんでした")

    return {"message": f"{filename} を作成しました"}

@app.delete("/api/delete/{filename}")
async def delete_script(filename: str):
    path = resolve_safe_path(filename)
    if not os.path.exists(path): raise HTTPException(status_code=404, detail="ファイルが見つかりません")
    if not os.path.isfile(path): raise HTTPException(status_code=400, detail="ファイルを指定してください")
    os.remove(path)
    return {"message": f"{filename} を削除しました"}

def _detect_terminal_cmd() -> Optional[str]:
    """利用可能なターミナルエミュレータを検出する。Wayland ネイティブを優先する。"""
    candidates = [
        "kitty",        # Wayland ネイティブ
        "alacritty",    # Wayland ネイティブ
        "foot",         # Wayland ネイティブ
        "gnome-terminal",  # Wayland 対応（Xwayland フォールバックあり）
        "xfce4-terminal",
        "konsole",
        "xterm",
        "ptyxis",
    ]
    for name in candidates:
        if shutil.which(name):
            return name
    return None


def _detect_gui_env() -> Tuple[Optional[str], Optional[str], Optional[str]]:
    """ログイン中の GUI セッションから DISPLAY / XAUTHORITY / WAYLAND_DISPLAY を検出する。

    Wayland セッションを正式にサポートし、X11 はフォールバックとして扱う。
    戻り値は (display, xauth, wayland_display) のタプル。
      - Wayland セッション: display=None, wayland_display="wayland-0" 等
      - X11 セッション:    display=":0" 等, wayland_display=None
      - 検出不可:          display=None, wayland_display=None
    """
    display = os.environ.get("DISPLAY")
    xauth = os.environ.get("XAUTHORITY")
    wayland_display = os.environ.get("WAYLAND_DISPLAY")

    uid = os.getuid()
    run_user = f"/run/user/{uid}"

    # Wayland セッションの検出（/run/user/$UID/wayland-* の存在）
    if not wayland_display and os.path.isdir(run_user):
        for entry in os.listdir(run_user):
            if entry.startswith("wayland-") and os.path.isdir(os.path.join(run_user, entry)):
                wayland_display = entry
                break

    # X11 フォールバック: Wayland が検出されず DISPLAY も無い場合は :0 をデフォルト
    if not wayland_display and not display:
        display = ":0"

    # XAUTHORITY の検出（優先度順）
    if not xauth:
        if os.path.isdir(run_user):
            for entry in os.listdir(run_user):
                if entry.startswith(".mutter-Xwaylandauth.") or entry == "Xauth":
                    candidate = os.path.join(run_user, entry)
                    if os.path.isfile(candidate):
                        xauth = candidate
                        break

        if not xauth:
            home_auth = os.path.join(os.environ.get("HOME", ""), ".Xauthority")
            if os.path.isfile(home_auth):
                xauth = home_auth

    return display, xauth, wayland_display


def _build_terminal_launch_cmd(term: str, script_path: str) -> list[str]:
    """ターミナルエミュレータごとにコマンドラインオプションを構築する。"""
    cmd_map = {
        "kitty": ["kitty", "--single-instance", "bash", script_path],
        "alacritty": ["alacritty", "--command", "bash", script_path],
        "foot": ["foot", "-e", "bash", script_path],
        "gnome-terminal": ["gnome-terminal", "--", "bash", script_path],
        "xfce4-terminal": ["xfce4-terminal", "-e", f"bash {script_path}"],
        "konsole": ["konsole", "-e", "bash", script_path],
        "xterm": ["xterm", "-e", "bash", script_path],
        "ptyxis": ["ptyxis", "--new-window", "-e", "bash", script_path],
    }
    return cmd_map.get(term, ["xterm", "-e", "bash", script_path])


@app.post("/api/execute/{filename}")
async def execute_script(filename: str):
    if not _is_executable(filename):
        raise HTTPException(status_code=403, detail="このスクリプトの実行は許可されていません")
    path = resolve_safe_path(filename)
    if not os.path.exists(path):
        raise HTTPException(status_code=404)

    term = _detect_terminal_cmd()
    if not term:
        raise HTTPException(status_code=500, detail="ターミナルエミュレータが見つかりません")

    # GUI セッションの検出（Wayland 優先、X11 はフォールバック）
    display, xauth, wayland_display = _detect_gui_env()

    if not wayland_display and not display:
        raise HTTPException(status_code=500, detail="GUIセッションが見つかりません。DISPLAY または WAYLAND_DISPLAY が設定されていません。")

    cmd = _build_terminal_launch_cmd(term, path)

    env = {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": os.environ.get("HOME", "/root"),
    }
    # Wayland 環境（優先）
    if wayland_display:
        env["WAYLAND_DISPLAY"] = wayland_display
        env["XDG_SESSION_TYPE"] = "wayland"
    # X11 環境（フォールバック、または Xwayland 経由での利用）
    if display:
        env["DISPLAY"] = display
        if not wayland_display:
            env["XDG_SESSION_TYPE"] = "x11"
    if xauth:
        env["XAUTHORITY"] = xauth

    # GTK/Wayland アプリに必要な環境変数を継承
    for key in ("DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR", "XDG_SESSION_ID", "GDK_BACKEND", "LANG", "LC_ALL"):
        val = os.environ.get(key)
        if val:
            env[key] = val

    try:
        subprocess.Popen(cmd, env=env, start_new_session=True)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"ターミナル起動に失敗しました: {e}")

    return {"message": f"{term} でスクリプトを実行しています", "terminal": term}

# ---- TCP ポングチェック（SSH:22番） ----

_ping_cache: dict = {}  # {"_ts": ts, host1: "online"|"offline", ...}


def _connect_one(host: str, port: int, timeout: float) -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
        sock.close()
        return True
    except Exception:
        sock.close()
        return False


_ping_pool = ThreadPoolExecutor(max_workers=10)


@app.get("/api/ping")
async def ping_all():
    """全スクリプトのホストに SSH ポートチェックを行い、状態を返す。"""
    global _ping_cache
    now = time.time()

    # キャッシュが有効なら即座に返す
    if _ping_cache and (now - _ping_cache.get("_ts", 0) < 5):
        return dict(_ping_cache)

    hosts = []
    if not os.path.exists(SCRIPT_DIR):
        raise HTTPException(status_code=404, detail="スクリプトディレクトリが見つかりません。config.json を確認してください。")
    files = [f for f in os.listdir(SCRIPT_DIR) if f.endswith(".sh")]
    for fname in files:
        info = parse_script_info(os.path.join(SCRIPT_DIR, fname))
        h = info.host
        if h and h not in ("N/A", "Unknown"):
            hosts.append(h)
    hosts = list(dict.fromkeys(hosts))  # dedup 順守

    results: dict = {"_ts": now}
    if hosts:
        loop = asyncio.get_event_loop()
        coros = [loop.run_in_executor(_ping_pool, _connect_one, h, 22, 3.0) for h in hosts]
        ok_list = await asyncio.gather(*coros)
        for h, ok in zip(hosts, ok_list):
            results[h] = "online" if ok else "offline"

    _ping_cache = results
    return dict(results)


@app.get("/")
async def read_index():
    index_path = os.path.join(STATIC_DIR, "index.html")
    if not os.path.exists(index_path):
        raise HTTPException(status_code=404, detail="index.html not found")
    return FileResponse(index_path)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("UVICORN_PORT", 8080)))
