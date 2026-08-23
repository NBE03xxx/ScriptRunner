import asyncio
import os
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

from fastapi import HTTPException

from app import main


class CreateScriptTests(unittest.TestCase):
    """スクリプト新規作成処理を検証する。"""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.script_dir = self.temp_dir.name
        self.patches = (
            patch.object(main, "SCRIPT_DIR", self.script_dir),
            patch.object(main, "_RESOLVED_SCRIPT_DIR", os.path.realpath(self.script_dir)),
        )
        for active_patch in self.patches:
            active_patch.start()

    def tearDown(self):
        for active_patch in reversed(self.patches):
            active_patch.stop()
        self.temp_dir.cleanup()

    @staticmethod
    def create(filename, content="#!/bin/bash\n"):
        return asyncio.run(main.create_script(filename, main.ScriptContent(content=content)))

    def test_create_script_with_bash_shebang(self):
        result = self.create("example.sh")

        with open(os.path.join(self.script_dir, "example.sh"), encoding="utf-8") as script:
            self.assertEqual(script.read(), "#!/bin/bash\n")
        self.assertEqual(result["message"], "example.sh を作成しました")

    def test_existing_script_is_not_overwritten(self):
        path = os.path.join(self.script_dir, "existing.sh")
        with open(path, "w", encoding="utf-8") as script:
            script.write("original\n")

        with self.assertRaises(HTTPException) as raised:
            self.create("existing.sh", "replacement\n")

        self.assertEqual(raised.exception.status_code, 409)
        with open(path, encoding="utf-8") as script:
            self.assertEqual(script.read(), "original\n")

    def test_only_one_concurrent_create_succeeds(self):
        def attempt():
            try:
                self.create("race.sh")
                return 201
            except HTTPException as error:
                return error.status_code

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: attempt(), range(2)))

        self.assertCountEqual(results, [201, 409])

    def test_rejects_invalid_filenames(self):
        invalid_names = ("", "name", ".sh", " name.sh", "name.sh ", "dir/name.sh", "dir\\name.sh", "bad\nname.sh")
        for filename in invalid_names:
            with self.subTest(filename=filename):
                with self.assertRaises(HTTPException) as raised:
                    main.validate_new_script_filename(filename)
                self.assertEqual(raised.exception.status_code, 400)

    def test_missing_script_directory_returns_404(self):
        missing_dir = os.path.join(self.script_dir, "missing")
        with patch.object(main, "SCRIPT_DIR", missing_dir), patch.object(
            main, "_RESOLVED_SCRIPT_DIR", os.path.realpath(missing_dir)
        ):
            with self.assertRaises(HTTPException) as raised:
                self.create("example.sh")

        self.assertEqual(raised.exception.status_code, 404)


if __name__ == "__main__":
    unittest.main()
