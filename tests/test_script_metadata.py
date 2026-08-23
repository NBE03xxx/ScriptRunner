import asyncio
import os
import tempfile
import unittest

from unittest.mock import patch

from app import main


class ScriptMetadataTests(unittest.TestCase):
    def parse(self, content):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "sample.sh")
            with open(path, "w", encoding="utf-8") as script:
                script.write(content)
            return main.parse_script_info(path)

    def test_metadata_defaults_and_existing_host_parsing(self):
        info = self.parse("#!/bin/bash\nssh user@example.local\n")
        self.assertEqual(info.group, "")
        self.assertEqual(info.tags, [])
        self.assertEqual(info.host, "example.local")

    def test_extracts_first_valid_group_and_unique_tags(self):
        info = self.parse(
            "#!/bin/bash\n"
            "# group:   Mastodon  \n"
            "# group: AI\n"
            "# tag: ssh\n"
            "# tag: maintenance\n"
            "# tag: ssh\n"
        )
        self.assertEqual(info.group, "Mastodon")
        self.assertEqual(info.tags, ["ssh", "maintenance"])

    def test_supports_japanese_and_ignores_empty_values(self):
        info = self.parse(
            "#!/bin/bash\n# group:   \n# group: 保守作業\n"
            "# tag: 日本語タグ\n# tag:   \n"
        )
        self.assertEqual(info.group, "保守作業")
        self.assertEqual(info.tags, ["日本語タグ"])

    def test_metadata_is_limited_to_first_30_lines_but_host_is_not(self):
        content = "#!/bin/bash\n" + "\n" * 29 + "# group: 遅すぎる\n# tag: 対象外\nssh late@10.0.0.8\n"
        info = self.parse(content)
        self.assertEqual(info.group, "")
        self.assertEqual(info.tags, [])
        self.assertEqual(info.host, "10.0.0.8")

    def test_whitelist_result_is_preserved(self):
        with patch.object(main, "_EXEC_WHITELIST", ["allowed.sh"]):
            with tempfile.TemporaryDirectory() as directory:
                path = os.path.join(directory, "blocked.sh")
                with open(path, "w", encoding="utf-8") as script:
                    script.write("#!/bin/bash\n# tag: ssh\n")
                self.assertFalse(main.parse_script_info(path).executable)

    def test_scripts_api_models_include_metadata_without_changing_existing_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "api.sh")
            with open(path, "w", encoding="utf-8") as script:
                script.write("#!/bin/bash\n# group: API\n# tag: test\n")
            with patch.object(main, "SCRIPT_DIR", directory):
                scripts = asyncio.run(main.list_scripts())

        data = scripts[0].model_dump()
        self.assertEqual(data["group"], "API")
        self.assertEqual(data["tags"], ["test"])
        self.assertTrue({"name", "path", "host", "mtime", "executable"} <= data.keys())


if __name__ == "__main__":
    unittest.main()
