"""現在のデスクトップセッションでスクリプト用ターミナルを起動する。"""

from __future__ import annotations

import os
import shlex
import shutil
import subprocess
from pathlib import Path

TERMINAL_CANDIDATES = (
    "kitty",
    "alacritty",
    "foot",
    "gnome-terminal",
    "xfce4-terminal",
    "konsole",
    "xterm",
    "ptyxis",
)


def detect_terminal() -> str | None:
    for name in TERMINAL_CANDIDATES:
        if shutil.which(name):
            return name
    return None


def build_terminal_command(terminal: str, script_path: str) -> list[str]:
    safe_shell_command = shlex.join(["bash", script_path])
    commands = {
        "kitty": ["kitty", "--single-instance", "bash", script_path],
        "alacritty": ["alacritty", "--command", "bash", script_path],
        "foot": ["foot", "-e", "bash", script_path],
        "gnome-terminal": ["gnome-terminal", "--", "bash", script_path],
        "xfce4-terminal": ["xfce4-terminal", "--command", safe_shell_command],
        "konsole": ["konsole", "-e", "bash", script_path],
        "xterm": ["xterm", "-e", "bash", script_path],
        "ptyxis": ["ptyxis", "--new-window", "--", "bash", script_path],
    }
    if terminal not in commands:
        raise ValueError(f"未対応のターミナルです: {terminal}")
    return commands[terminal]


def validate_target_path(script_path: str, script_dir: str) -> str:
    """バックエンドが返した対象が保存先直下のシェルスクリプトか確認する。"""
    resolved_path = os.path.realpath(script_path)
    resolved_dir = os.path.realpath(script_dir)
    try:
        is_inside = os.path.commonpath((resolved_path, resolved_dir)) == resolved_dir
    except ValueError:
        is_inside = False
    if not is_inside or os.path.dirname(resolved_path) != resolved_dir:
        raise ValueError("実行対象がスクリプト保存先の直下にありません")
    if not resolved_path.endswith(".sh") or not os.path.isfile(resolved_path):
        raise ValueError("実行対象のシェルスクリプトが見つかりません")
    return resolved_path


def launch_script(script_path: str, script_dir: str) -> tuple[str, int]:
    """バックエンドとGTK側で検証済みの対象を独立した端末で起動する。"""
    path = validate_target_path(script_path, script_dir)
    terminal = detect_terminal()
    if not terminal:
        raise RuntimeError("対応するターミナルエミュレーターが見つかりません")
    command = build_terminal_command(terminal, str(Path(path)))
    process = subprocess.Popen(
        command,
        env=dict(os.environ),
        start_new_session=True,
    )
    return terminal, process.pid
