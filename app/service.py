"""systemdユーザーサービス用のScript Runner起動処理。"""

from __future__ import annotations

import asyncio
import contextlib
import os
import secrets
import signal
import time
import threading
import uuid

import uvicorn
from uvicorn.server import HANDLED_SIGNALS

from app import main
from app.runtime import (
    ConnectionInfo,
    SCHEMA_VERSION,
    create_listen_socket,
    remove_connection_info,
    write_connection_info,
)


class DesktopServiceServer(uvicorn.Server):
    """終了シグナル再送出前にランタイム情報を清掃できるサーバー。"""

    @contextlib.contextmanager
    def capture_signals(self):
        if threading.current_thread() is not threading.main_thread():
            yield
            return
        original_handlers = {
            handled_signal: signal.signal(handled_signal, self.handle_exit)
            for handled_signal in HANDLED_SIGNALS
        }
        try:
            yield
        finally:
            for handled_signal, handler in original_handlers.items():
                signal.signal(handled_signal, handler)


async def serve() -> None:
    runtime_token = secrets.token_urlsafe(32)
    instance_id = uuid.uuid4().hex
    main.configure_desktop_service(runtime_token, instance_id)
    listen_socket = create_listen_socket()
    port = int(listen_socket.getsockname()[1])
    config = uvicorn.Config(
        main.app,
        host="127.0.0.1",
        port=port,
        access_log=False,
        log_level="info",
    )
    server = DesktopServiceServer(config)
    server_task = asyncio.create_task(server.serve(sockets=[listen_socket]))

    try:
        for _ in range(200):
            if server.started:
                break
            if server_task.done():
                await server_task
            await asyncio.sleep(0.05)
        else:
            server.should_exit = True
            raise RuntimeError("FastAPIサービスの起動確認がタイムアウトしました")

        write_connection_info(
            ConnectionInfo(
                schema_version=SCHEMA_VERSION,
                pid=os.getpid(),
                host="127.0.0.1",
                port=port,
                token=runtime_token,
                instance_id=instance_id,
                started_at=time.time(),
            )
        )
        await server_task
    finally:
        server.should_exit = True
        if not server_task.done():
            await server_task
        remove_connection_info(instance_id)
        listen_socket.close()


def main_entry() -> None:
    asyncio.run(serve())


if __name__ == "__main__":
    main_entry()
