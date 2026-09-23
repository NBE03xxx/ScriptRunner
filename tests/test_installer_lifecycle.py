import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class InstallerLifecycleTests(unittest.TestCase):
    """実ユーザー環境を変更せず、導入・更新・復元・削除を検証する。"""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.install_dir = self.home / "ScriptRunner"
        self.runtime_dir = self.root / "runtime"
        self.runtime_dir.mkdir(mode=0o700)
        self.external_scripts = self.root / "external scripts"
        self.external_scripts.mkdir()
        self.fake_bin = self.root / "fake-bin"
        self.fake_bin.mkdir()
        self._write_fake_systemctl()
        self._write_fake_python()

        self.environment = dict(os.environ)
        self.environment.update(
            {
                "HOME": str(self.home),
                "PATH": f"{self.fake_bin}:{self.environment['PATH']}",
                "XDG_RUNTIME_DIR": str(self.runtime_dir),
                "SCRIPT_RUNNER_LANG": "en",
                "SCRIPT_RUNNER_INSTALL_DIR": str(self.install_dir),
                "SCRIPT_RUNNER_SOURCE_DIR": str(PROJECT_DIR),
                "PIP_NO_INDEX": "1",
                "PIP_NO_DEPS": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
            }
        )
        for name in ("DISPLAY", "WAYLAND_DISPLAY"):
            self.environment.pop(name, None)

    def tearDown(self):
        self.temp_dir.cleanup()

    def _write_fake_systemctl(self):
        path = self.fake_bin / "systemctl"
        path.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -u
                command_name="${2:-}"
                case "$command_name" in
                    is-active) [[ -f "$HOME/.fake-service-active" ]] ;;
                    is-enabled) [[ -f "$HOME/.fake-service-enabled" ]] ;;
                    start)
                        [[ "${FAKE_SYSTEMCTL_FAIL_START:-0}" == 1 ]] && exit 1
                        mkdir -p "$XDG_RUNTIME_DIR/script-runner"
                        printf '%s\n' \
                            '{"host":"127.0.0.1","port":43210,"token":"01234567890123456789012345678901","pid":1,"instance_id":"test"}' \
                            >"$XDG_RUNTIME_DIR/script-runner/connection.json"
                        touch "$HOME/.fake-service-active"
                        ;;
                    stop)
                        [[ "${FAKE_SYSTEMCTL_FAIL_STOP:-0}" == 1 ]] && exit 1
                        rm -f "$XDG_RUNTIME_DIR/script-runner/connection.json"
                        rm -f "$HOME/.fake-service-active"
                        ;;
                    enable) touch "$HOME/.fake-service-enabled" ;;
                    disable) rm -f "$HOME/.fake-service-enabled" ;;
                    daemon-reload) ;;
                    *) ;;
                esac
                """
            ),
            encoding="utf-8",
        )
        path.chmod(0o755)

    def _write_fake_python(self):
        """ソケット制限下では接続検査だけを代替し、他は実Pythonへ渡す。"""
        path = self.fake_bin / "python3"
        path.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                if [[ "${1:-}" == - && "${2:-}" == */script-runner/connection.json ]]; then
                    exit 0
                fi
                exec /usr/bin/python3 "$@"
                """
            ),
            encoding="utf-8",
        )
        path.chmod(0o755)

    def _run_install(self, answers, *, fail_start=False):
        environment = dict(self.environment)
        if fail_start:
            environment["FAKE_SYSTEMCTL_FAIL_START"] = "1"
        return subprocess.run(
            ["bash", str(PROJECT_DIR / "install.sh")],
            input=answers,
            text=True,
            capture_output=True,
            env=environment,
            cwd=PROJECT_DIR,
            timeout=60,
        )

    def _run_uninstall(self, answers, *, fail_stop=False):
        environment = dict(self.environment)
        if fail_stop:
            environment["FAKE_SYSTEMCTL_FAIL_STOP"] = "1"
        return subprocess.run(
            ["bash", str(PROJECT_DIR / "uninstall.sh")],
            input=answers,
            text=True,
            capture_output=True,
            env=environment,
            cwd=PROJECT_DIR,
            timeout=30,
        )

    def test_new_install_update_rollback_and_uninstall(self):
        first = self._run_install(f"{self.external_scripts}\n")
        diagnostics = first.stdout + first.stderr
        self.assertEqual(first.returncode, 0, diagnostics)
        self.assertTrue((self.install_dir / "app" / "desktop.py").is_file())
        self.assertTrue((self.install_dir / "venv" / "bin" / "python").is_file())
        self.assertTrue(
            (self.home / ".config/systemd/user/script-runner.service").is_file()
        )
        self.assertTrue(
            (
                self.home
                / ".local/share/applications/com.nbe03xxx.ScriptRunner.desktop"
            ).is_file()
        )
        config = json.loads((self.install_dir / "config.json").read_text(encoding="utf-8"))
        self.assertEqual(config["script_dir"], str(self.external_scripts))
        config["custom_setting"] = "更新後も保持"
        (self.install_dir / "config.json").write_text(
            json.dumps(config, ensure_ascii=False), encoding="utf-8"
        )

        installed_main = self.install_dir / "app" / "main.py"
        installed_main.write_text("更新前\n", encoding="utf-8")
        update = self._run_install(f"y\n{self.external_scripts}\n")
        self.assertEqual(update.returncode, 0, update.stdout + update.stderr)
        self.assertEqual(
            installed_main.read_bytes(), (PROJECT_DIR / "app/main.py").read_bytes()
        )
        updated_config = json.loads(
            (self.install_dir / "config.json").read_text(encoding="utf-8")
        )
        self.assertEqual(updated_config["script_dir"], str(self.external_scripts))
        self.assertEqual(updated_config["custom_setting"], "更新後も保持")

        installed_main.write_text("ロールバック対象\n", encoding="utf-8")
        service_file = self.home / ".config/systemd/user/script-runner.service"
        desktop_file = (
            self.home / ".local/share/applications/com.nbe03xxx.ScriptRunner.desktop"
        )
        service_file.write_text("更新前サービス\n", encoding="utf-8")
        desktop_file.write_text("更新前デスクトップ\n", encoding="utf-8")
        venv_marker = self.install_dir / "venv" / "更新前"
        venv_marker.write_text("保持", encoding="utf-8")

        failed = self._run_install(
            f"y\n{self.external_scripts}\n", fail_start=True
        )
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        self.assertEqual(installed_main.read_text(encoding="utf-8"), "ロールバック対象\n")
        self.assertEqual(service_file.read_text(encoding="utf-8"), "更新前サービス\n")
        self.assertEqual(desktop_file.read_text(encoding="utf-8"), "更新前デスクトップ\n")
        self.assertTrue(venv_marker.is_file())

        script = self.external_scripts / "保持対象.sh"
        script.write_text("#!/bin/bash\n", encoding="utf-8")
        (self.home / ".fake-service-active").touch()
        uninstall = self._run_uninstall("y\nn\nn\ny\n")
        self.assertEqual(uninstall.returncode, 0, uninstall.stdout + uninstall.stderr)
        self.assertFalse(self.install_dir.exists())
        self.assertTrue(script.is_file())
        self.assertFalse(service_file.exists())
        self.assertFalse(desktop_file.exists())

    def test_abandoned_folder_selection_keeps_existing_service_running(self):
        (self.install_dir / "app").mkdir(parents=True)
        existing_app = self.install_dir / "app/main.py"
        existing_app.write_text("旧版\n", encoding="utf-8")
        service_file = self.home / ".config/systemd/user/script-runner.service"
        service_file.parent.mkdir(parents=True)
        service_file.write_text("旧サービス\n", encoding="utf-8")
        (self.home / ".fake-service-active").touch()

        result = self._run_install("y\n")

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.home / ".fake-service-active").exists())
        self.assertEqual(existing_app.read_text(encoding="utf-8"), "旧版\n")
        self.assertEqual(service_file.read_text(encoding="utf-8"), "旧サービス\n")

    def test_uninstall_does_not_delete_files_if_service_stop_fails(self):
        (self.install_dir / "app").mkdir(parents=True)
        existing_app = self.install_dir / "app/main.py"
        existing_app.write_text("稼働中\n", encoding="utf-8")
        service_file = self.home / ".config/systemd/user/script-runner.service"
        service_file.parent.mkdir(parents=True)
        service_file.write_text("稼働中サービス\n", encoding="utf-8")
        (self.home / ".fake-service-active").touch()
        (self.home / ".fake-service-enabled").touch()

        result = self._run_uninstall("y\ny\n", fail_stop=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(existing_app.is_file())
        self.assertTrue(service_file.is_file())
        self.assertTrue((self.home / ".fake-service-active").is_file())


if __name__ == "__main__":
    unittest.main()
