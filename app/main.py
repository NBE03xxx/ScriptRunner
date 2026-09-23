import asyncio
import hmac
import json
import os
import re
import socket
import time
from concurrent.futures import ThreadPoolExecutor
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from typing import List, Optional, Tuple

app = FastAPI()

# Directory settings - use the example in a clean checkout before installation.
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_PATH = os.path.join(PROJECT_DIR, "config.json")
EXAMPLE_CONFIG_PATH = os.path.join(PROJECT_DIR, "config.example.json")
def load_config(path: str) -> dict:
    """設定ファイルを読み込む。相対パスは設定ファイルのあるディレクトリを基準に解決する。"""
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

CONFIG = load_config(CONFIG_PATH if os.path.isfile(CONFIG_PATH) else EXAMPLE_CONFIG_PATH)
SCRIPT_DIR = os.path.join(PROJECT_DIR, CONFIG.get("script_dir", "bin"))
STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
DESKTOP_MODE = False
RUNTIME_TOKEN: Optional[str] = None
RUNTIME_INSTANCE_ID: Optional[str] = None


def configure_desktop_service(runtime_token: str, instance_id: str) -> None:
    """デスクトップサービス用の起動時トークンを設定する。"""
    global DESKTOP_MODE, RUNTIME_TOKEN, RUNTIME_INSTANCE_ID
    if not runtime_token or not instance_id:
        raise ValueError("runtime_token and instance_id must not be empty")
    DESKTOP_MODE = True
    RUNTIME_TOKEN = runtime_token
    RUNTIME_INSTANCE_ID = instance_id

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
       request.url.path == "/api/token-required" or \
       request.url.path.startswith("/desktop/bootstrap/"):
        return await call_next(request)

    cookie_token = request.cookies.get("script_runner_session")
    expected_token = RUNTIME_TOKEN
    supplied_token = cookie_token
    if not DESKTOP_MODE or not expected_token:
        return JSONResponse(
            status_code=503,
            content={"detail": "デスクトップサービスが初期化されていません"},
        )
    token_matches = bool(
        expected_token
        and supplied_token
        and hmac.compare_digest(supplied_token, expected_token)
    )
    if expected_token and not token_matches:
        hint = ""
        if supplied_token is None:
            hint = "認証情報が送信されていません"
        elif len(supplied_token) != len(expected_token):
            hint = "認証情報の長さが異なります"
        else:
            hint = "認証情報が一致しません"
        return JSONResponse(status_code=401, content={"detail": f"認証に失敗しました: {hint}"})

    response = await call_next(request)
    return response


@app.get("/api/token-required")
async def is_token_required():
    """デスクトップサービスの初期化状態を返す。"""
    if DESKTOP_MODE:
        return {"required": False, "mode": "desktop"}
    return {"required": True, "mode": "unconfigured"}


@app.get("/api/health")
async def desktop_health():
    """認証済みのGTKアプリへ現在のサービスインスタンスを返す。"""
    if not DESKTOP_MODE or not RUNTIME_INSTANCE_ID:
        raise HTTPException(status_code=503, detail="サービスが初期化されていません")
    return {"instance_id": RUNTIME_INSTANCE_ID}


@app.get("/desktop/bootstrap/{token}", include_in_schema=False)
async def desktop_bootstrap(token: str):
    """GTKアプリからの接続をセッションCookieへ交換する。"""
    if not DESKTOP_MODE or not RUNTIME_TOKEN or not hmac.compare_digest(token, RUNTIME_TOKEN):
        raise HTTPException(status_code=403, detail="デスクトップセッションを確認できません")
    response = RedirectResponse(url="/", status_code=303)
    response.set_cookie(
        "script_runner_session",
        RUNTIME_TOKEN,
        httponly=True,
        samesite="strict",
        path="/",
    )
    return response

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


def validate_execution_target(filename: str) -> str:
    """実行可能なスクリプトを検証し、安全な絶対パスを返す。"""
    if not filename.endswith(".sh") or os.path.basename(filename) != filename:
        raise HTTPException(status_code=400, detail="有効なスクリプト名を指定してください")
    if not _is_executable(filename):
        raise HTTPException(status_code=403, detail="このスクリプトの実行は許可されていません")
    path = resolve_safe_path(filename)
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="スクリプトが見つかりません")
    return path


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


class ExecutionTarget(BaseModel):
    """GTK側が再検証して実行する対象。"""

    path: str
    script_dir: str


@app.get("/api/execution-target/{filename}", response_model=ExecutionTarget)
async def get_execution_target(filename: str):
    """最新のホワイトリストと保存先設定に基づく実行対象を返す。"""
    path = validate_execution_target(filename)
    return ExecutionTarget(path=path, script_dir=_RESOLVED_SCRIPT_DIR)


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
