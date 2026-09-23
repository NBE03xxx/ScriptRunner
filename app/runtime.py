"""ユーザーサービスとデスクトップアプリ間の接続情報を管理する。"""

from __future__ import annotations

import json
import os
import socket
import stat
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


RUNTIME_SUBDIR = "script-runner"
CONNECTION_FILENAME = "connection.json"
SCHEMA_VERSION = 1


@dataclass(frozen=True)
class ConnectionInfo:
    schema_version: int
    pid: int
    host: str
    port: int
    token: str
    instance_id: str
    started_at: float

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "ConnectionInfo":
        info = cls(
            schema_version=int(value["schema_version"]),
            pid=int(value["pid"]),
            host=str(value["host"]),
            port=int(value["port"]),
            token=str(value["token"]),
            instance_id=str(value["instance_id"]),
            started_at=float(value["started_at"]),
        )
        if info.schema_version != SCHEMA_VERSION:
            raise ValueError("未対応の接続情報バージョンです")
        if info.host != "127.0.0.1" or not 1 <= info.port <= 65535:
            raise ValueError("接続先が不正です")
        if not info.token or not info.instance_id or info.pid <= 0:
            raise ValueError("接続情報が不足しています")
        return info


def _validate_owned_directory(path: Path, mode: int, *, repair_permissions: bool = False) -> None:
    details = path.lstat()
    if stat.S_ISLNK(details.st_mode) or not stat.S_ISDIR(details.st_mode):
        raise RuntimeError(f"安全なディレクトリではありません: {path}")
    if details.st_uid != os.getuid():
        raise RuntimeError(f"ディレクトリの所有者が異なります: {path}")
    current_mode = stat.S_IMODE(details.st_mode)
    if current_mode & 0o077:
        if not repair_permissions:
            raise RuntimeError(f"ディレクトリの権限が広すぎます: {path}")
        os.chmod(path, mode)


def get_runtime_directory() -> Path:
    """安全なアプリ専用ランタイムディレクトリを返す。"""
    raw_base = os.environ.get("XDG_RUNTIME_DIR")
    if not raw_base:
        raise RuntimeError("XDG_RUNTIME_DIR が設定されていません")
    base = Path(raw_base)
    if not base.is_absolute():
        raise RuntimeError("XDG_RUNTIME_DIR は絶対パスである必要があります")
    _validate_owned_directory(base, 0o700)

    runtime_dir = base / RUNTIME_SUBDIR
    try:
        runtime_dir.mkdir(mode=0o700)
    except FileExistsError:
        pass
    _validate_owned_directory(runtime_dir, 0o700, repair_permissions=True)
    return runtime_dir


def get_connection_path() -> Path:
    return get_runtime_directory() / CONNECTION_FILENAME


def create_listen_socket() -> socket.socket:
    """ループバックの空きポートへバインド済みのソケットを返す。"""
    listen_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listen_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listen_socket.bind(("127.0.0.1", 0))
    listen_socket.listen(socket.SOMAXCONN)
    listen_socket.set_inheritable(False)
    return listen_socket


def write_connection_info(info: ConnectionInfo) -> Path:
    """接続情報を0600の一時ファイル経由で原子的に公開する。"""
    runtime_dir = get_runtime_directory()
    target = runtime_dir / CONNECTION_FILENAME
    descriptor, temporary_name = tempfile.mkstemp(prefix=".connection-", dir=runtime_dir)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(asdict(info), stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
        os.chmod(target, 0o600)
        return target
    except Exception:
        try:
            os.close(descriptor)
        except OSError:
            pass
        temporary.unlink(missing_ok=True)
        raise


def read_connection_info() -> ConnectionInfo:
    """所有者と権限を検証して接続情報を読み込む。"""
    path = get_connection_path()
    details = path.lstat()
    if stat.S_ISLNK(details.st_mode) or not stat.S_ISREG(details.st_mode):
        raise RuntimeError("接続情報が通常ファイルではありません")
    if details.st_uid != os.getuid() or stat.S_IMODE(details.st_mode) & 0o077:
        raise RuntimeError("接続情報の所有者または権限が不正です")
    with path.open(encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError("接続情報の形式が不正です")
    return ConnectionInfo.from_dict(value)


def remove_connection_info(instance_id: str) -> None:
    """同じサービスインスタンスが公開した接続情報だけを削除する。"""
    try:
        info = read_connection_info()
    except (FileNotFoundError, OSError, ValueError, RuntimeError, json.JSONDecodeError):
        return
    if info.instance_id == instance_id:
        get_connection_path().unlink(missing_ok=True)
