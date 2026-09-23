"""GTK4 + WebKitGTK 6.0によるScript Runnerデスクトップアプリ。"""

from __future__ import annotations

import json
import sys
import urllib.request
from urllib.parse import quote

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("WebKit", "6.0")

from gi.repository import Gdk, Gio, GLib, Gtk, WebKit  # noqa: E402

from app.runtime import ConnectionInfo, read_connection_info  # noqa: E402
from app.terminal import launch_script  # noqa: E402


APPLICATION_ID = "com.nbe03xxx.ScriptRunner"
CONNECTION_RETRY_MS = 200
CONNECTION_RETRY_LIMIT = 50


def _prefers_dark_theme() -> bool:
    """初回描画前の背景色に、デスクトップのテーマ設定を反映する。"""
    source = Gio.SettingsSchemaSource.get_default()
    schema = source.lookup("org.gnome.desktop.interface", True) if source else None
    if schema and schema.has_key("color-scheme"):
        color_scheme = Gio.Settings.new_full(schema, None, None).get_string("color-scheme")
        if color_scheme == "prefer-dark":
            return True
        if color_scheme == "prefer-light":
            return False

    settings = Gtk.Settings.get_default()
    if settings is None:
        return False
    return bool(settings.get_property("gtk-application-prefer-dark-theme")) or str(
        settings.get_property("gtk-theme-name")
    ).lower().endswith("-dark")


class ScriptRunnerApplication(Gtk.Application):
    def __init__(self) -> None:
        super().__init__(
            application_id=APPLICATION_ID,
            flags=Gio.ApplicationFlags.DEFAULT_FLAGS,
        )
        self.window: Gtk.ApplicationWindow | None = None
        self.web_view: WebKit.WebView | None = None
        self.connection: ConnectionInfo | None = None
        self.retry_count = 0
        self.connect("activate", self._on_activate)

    def _on_activate(self, _application: Gtk.Application) -> None:
        if self.window is not None:
            self.window.present()
            return

        self.window = Gtk.ApplicationWindow(application=self)
        self.window.set_title("Script Runner")
        self.window.set_icon_name("script-runner")
        self.window.set_default_size(1100, 760)
        self.window.maximize()
        self._show_status("Script Runnerを準備しています…")
        self.window.present()
        GLib.timeout_add(CONNECTION_RETRY_MS, self._connect_to_service)

    def _show_status(self, message: str, *, error: bool = False) -> None:
        if self.window is None:
            return
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        box.set_halign(Gtk.Align.CENTER)
        box.set_valign(Gtk.Align.CENTER)
        title = Gtk.Label()
        title.set_markup("<span size='xx-large' weight='bold'>☕ Script Runner</span>")
        detail = Gtk.Label(label=message)
        detail.set_wrap(True)
        detail.set_justify(Gtk.Justification.CENTER)
        if error:
            detail.add_css_class("error")
            retry = Gtk.Button(label="再接続")
            retry.connect("clicked", self._retry_connection)
            box.append(title)
            box.append(detail)
            box.append(retry)
        else:
            spinner = Gtk.Spinner()
            spinner.start()
            box.append(title)
            box.append(spinner)
            box.append(detail)
        self.window.set_child(box)

    def _retry_connection(self, _button: Gtk.Button) -> None:
        self.retry_count = 0
        self._show_status("ユーザーサービスへ再接続しています…")
        GLib.timeout_add(CONNECTION_RETRY_MS, self._connect_to_service)

    def _connect_to_service(self) -> bool:
        try:
            connection = read_connection_info()
            self._verify_service_instance(connection)
        except Exception as error:
            self.retry_count += 1
            if self.retry_count < CONNECTION_RETRY_LIMIT:
                return GLib.SOURCE_CONTINUE
            self._show_status(
                "Script Runnerサービスへ接続できません。\n"
                "systemctl --user status script-runner で状態を確認してください。\n\n"
                f"詳細: {error}",
                error=True,
            )
            return GLib.SOURCE_REMOVE

        self.connection = connection
        self._create_web_view(connection)
        return GLib.SOURCE_REMOVE

    @staticmethod
    def _verify_service_instance(connection: ConnectionInfo) -> None:
        """公開済み接続情報が現在のサービスを指すか確認する。"""
        request = urllib.request.Request(
            f"http://{connection.host}:{connection.port}/api/health",
            headers={"Cookie": f"script_runner_session={connection.token}"},
        )
        with urllib.request.urlopen(request, timeout=1) as response:
            result = json.load(response)
        if result.get("instance_id") != connection.instance_id:
            raise RuntimeError("接続情報が古いサービスを指しています")

    def _create_web_view(self, connection: ConnectionInfo) -> None:
        if self.window is None:
            return
        manager = WebKit.UserContentManager.new()
        manager.connect("script-message-received::runScript", self._on_run_script)
        manager.connect("script-message-received::reconnect", self._on_reconnect)
        manager.register_script_message_handler("runScript")
        manager.register_script_message_handler("reconnect")
        network_session = WebKit.NetworkSession.new_ephemeral()
        self.web_view = WebKit.WebView(
            network_session=network_session,
            user_content_manager=manager,
        )
        background = Gdk.RGBA()
        background.parse("#1a1a2e" if _prefers_dark_theme() else "#f5f0e1")
        self.web_view.set_background_color(background)
        settings = self.web_view.get_settings()
        settings.set_enable_developer_extras(False)
        self.web_view.connect("decide-policy", self._on_decide_policy)
        self.web_view.connect("web-process-terminated", self._on_web_process_terminated)
        self.window.set_child(self.web_view)
        token = quote(connection.token, safe="")
        self.web_view.load_uri(
            f"http://{connection.host}:{connection.port}/desktop/bootstrap/{token}"
        )

    def _on_decide_policy(self, _view, decision, decision_type) -> bool:
        if decision_type != WebKit.PolicyDecisionType.NAVIGATION_ACTION:
            return False
        request = decision.get_navigation_action().get_request()
        uri = request.get_uri()
        if self.connection is not None:
            allowed = f"http://{self.connection.host}:{self.connection.port}/"
            if uri.startswith(allowed) or uri == "about:blank":
                decision.use()
                return True
        decision.ignore()
        return True

    def _on_run_script(self, _manager, value) -> None:
        try:
            filename = value.to_string()
            target = self._request_execution_target(filename)
            terminal, _pid = launch_script(target["path"], target["script_dir"])
            self._notify_web(f"{terminal}で実行: {filename}", "success")
        except Exception as error:
            self._notify_web(str(error), "error")

    def _request_execution_target(self, filename: str) -> dict[str, str]:
        """サービスへ最新の実行可否を問い合わせる。"""
        if self.connection is None:
            raise RuntimeError("Script Runnerサービスへ接続されていません")
        encoded_filename = quote(filename, safe="")
        url = (
            f"http://{self.connection.host}:{self.connection.port}"
            f"/api/execution-target/{encoded_filename}"
        )
        request = urllib.request.Request(
            url,
            headers={"Cookie": f"script_runner_session={self.connection.token}"},
        )
        with urllib.request.urlopen(request, timeout=2) as response:
            payload = json.load(response)
        path = payload.get("path")
        script_dir = payload.get("script_dir")
        if not isinstance(path, str) or not isinstance(script_dir, str):
            raise RuntimeError("サービスから不正な実行対象が返されました")
        return {"path": path, "script_dir": script_dir}

    def _on_reconnect(self, _manager, _value) -> None:
        self.retry_count = 0
        self._show_status("ユーザーサービスへ再接続しています…")
        GLib.timeout_add(CONNECTION_RETRY_MS, self._connect_to_service)

    def _notify_web(self, message: str, status_type: str) -> None:
        if self.web_view is None:
            return
        script = f"showStatus({json.dumps(message)}, {json.dumps(status_type)});"
        self.web_view.evaluate_javascript(script, -1, None, None, None, None, None)

    def _on_web_process_terminated(self, _view, _reason) -> None:
        self._show_status(
            "画面プロセスが予期せず終了しました。再接続してください。",
            error=True,
        )


def main() -> int:
    application = ScriptRunnerApplication()
    return int(application.run(sys.argv))


if __name__ == "__main__":
    raise SystemExit(main())
