import asyncio
import unittest
from unittest.mock import patch

from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse

from app import main


def make_request(cookie=None):
    headers = []
    if cookie is not None:
        headers.append((b"cookie", f"script_runner_session={cookie}".encode()))
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": "/api/scripts",
            "headers": headers,
            "query_string": b"",
            "server": ("127.0.0.1", 1),
            "client": ("127.0.0.1", 2),
            "scheme": "http",
        }
    )


async def successful_next(_request):
    return JSONResponse({"ok": True})


class DesktopAuthenticationTests(unittest.TestCase):
    def setUp(self):
        self.patches = (
            patch.object(main, "DESKTOP_MODE", True),
            patch.object(main, "RUNTIME_TOKEN", "desktop-runtime-token"),
        )
        for active_patch in self.patches:
            active_patch.start()

    def tearDown(self):
        for active_patch in reversed(self.patches):
            active_patch.stop()

    def test_bootstrap_exchanges_runtime_token_for_http_only_cookie(self):
        response = asyncio.run(main.desktop_bootstrap("desktop-runtime-token"))

        self.assertEqual(response.status_code, 303)
        cookie = response.headers["set-cookie"]
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=strict", cookie)

    def test_invalid_bootstrap_token_is_rejected(self):
        with self.assertRaises(HTTPException) as raised:
            asyncio.run(main.desktop_bootstrap("wrong-token"))
        self.assertEqual(raised.exception.status_code, 403)

    def test_api_rejects_request_without_desktop_cookie(self):
        response = asyncio.run(main.authenticate(make_request(), successful_next))
        self.assertEqual(response.status_code, 401)

    def test_api_accepts_valid_desktop_cookie(self):
        response = asyncio.run(
            main.authenticate(make_request("desktop-runtime-token"), successful_next)
        )
        self.assertEqual(response.status_code, 200)

    def test_token_status_hides_runtime_secret_details(self):
        response = asyncio.run(main.is_token_required())
        self.assertEqual(response, {"required": False, "mode": "desktop"})


if __name__ == "__main__":
    unittest.main()
