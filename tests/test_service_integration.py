import http.cookiejar
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path


class ServiceIntegrationTests(unittest.TestCase):
    def test_service_publishes_authenticated_dynamic_connection_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as runtime_base:
            os.chmod(runtime_base, 0o700)
            environment = dict(os.environ)
            environment["XDG_RUNTIME_DIR"] = runtime_base
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            process = subprocess.Popen(
                [sys.executable, "-m", "app.service"],
                cwd=Path(__file__).resolve().parents[1],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            connection_path = Path(runtime_base) / "script-runner" / "connection.json"
            try:
                for _ in range(100):
                    if connection_path.exists():
                        break
                    if process.poll() is not None:
                        _stdout, stderr = process.communicate(timeout=1)
                        if "Operation not permitted" in stderr:
                            self.skipTest("実行サンドボックスがローカルソケットを禁止しています")
                        self.fail(f"サービスが起動前に終了しました: {stderr}")
                    time.sleep(0.05)
                else:
                    self.fail("接続情報が公開されませんでした")

                info = json.loads(connection_path.read_text(encoding="utf-8"))
                base_url = f"http://{info['host']}:{info['port']}"
                opener = urllib.request.build_opener(
                    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
                )
                response = opener.open(
                    f"{base_url}/desktop/bootstrap/{info['token']}", timeout=3
                )
                self.assertEqual(response.status, 200)
                scripts_response = opener.open(f"{base_url}/api/scripts", timeout=3)
                self.assertEqual(scripts_response.status, 200)
                self.assertEqual(json.load(scripts_response), [])
                health_response = opener.open(f"{base_url}/api/health", timeout=3)
                self.assertEqual(
                    json.load(health_response)["instance_id"], info["instance_id"]
                )
            finally:
                if process.poll() is None:
                    process.terminate()
                stdout, stderr = process.communicate(timeout=5)

            self.assertFalse(
                connection_path.exists(),
                f"接続情報が残っています。stdout={stdout!r} stderr={stderr!r}",
            )


if __name__ == "__main__":
    unittest.main()
