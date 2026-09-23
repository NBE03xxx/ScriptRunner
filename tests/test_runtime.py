import json
import os
import socket
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from app import runtime


class RuntimeConnectionTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        os.chmod(self.temp_dir.name, 0o700)
        self.environment = patch.dict(os.environ, {"XDG_RUNTIME_DIR": self.temp_dir.name})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.temp_dir.cleanup()

    @staticmethod
    def info(instance_id="instance-a"):
        return runtime.ConnectionInfo(
            schema_version=runtime.SCHEMA_VERSION,
            pid=os.getpid(),
            host="127.0.0.1",
            port=43210,
            token="temporary-token",
            instance_id=instance_id,
            started_at=1.0,
        )

    def test_connection_info_is_written_atomically_with_private_permissions(self):
        path = runtime.write_connection_info(self.info())

        self.assertEqual(runtime.read_connection_info(), self.info())
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        self.assertEqual(list(path.parent.glob(".connection-*")), [])

    def test_only_matching_instance_removes_connection_info(self):
        path = runtime.write_connection_info(self.info())

        runtime.remove_connection_info("another-instance")
        self.assertTrue(path.exists())
        runtime.remove_connection_info("instance-a")
        self.assertFalse(path.exists())

    def test_rejects_invalid_connection_target(self):
        path = runtime.write_connection_info(self.info())
        value = json.loads(path.read_text(encoding="utf-8"))
        value["host"] = "0.0.0.0"
        path.write_text(json.dumps(value), encoding="utf-8")
        os.chmod(path, 0o600)

        with self.assertRaises(ValueError):
            runtime.read_connection_info()

    def test_listen_socket_is_bound_to_loopback_dynamic_port(self):
        try:
            listen_socket = runtime.create_listen_socket()
        except PermissionError:
            self.skipTest("実行サンドボックスがローカルソケット作成を許可していません")
        try:
            host, port = listen_socket.getsockname()
            self.assertEqual(host, "127.0.0.1")
            self.assertGreater(port, 0)
            with socket.create_connection((host, port), timeout=1):
                pass
        finally:
            listen_socket.close()

    def test_rejects_missing_runtime_directory_environment(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(RuntimeError):
                runtime.get_runtime_directory()

    def test_rejects_symlink_as_application_runtime_directory(self):
        target = Path(self.temp_dir.name) / "actual"
        target.mkdir()
        os.chmod(target, 0o700)
        (Path(self.temp_dir.name) / runtime.RUNTIME_SUBDIR).symlink_to(target)

        with self.assertRaises(RuntimeError):
            runtime.get_runtime_directory()


if __name__ == "__main__":
    unittest.main()
