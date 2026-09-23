import tempfile
import unittest
from pathlib import Path

from app import terminal


class TerminalCommandTests(unittest.TestCase):
    def test_terminals_receive_bash_and_script_as_separate_arguments(self):
        path = "/tmp/日本語 script.sh"
        for name in ("kitty", "alacritty", "foot", "gnome-terminal", "konsole", "xterm", "ptyxis"):
            with self.subTest(name=name):
                command = terminal.build_terminal_command(name, path)
                self.assertIn("bash", command)
                self.assertIn(path, command)

    def test_xfce_command_quotes_spaces(self):
        command = terminal.build_terminal_command("xfce4-terminal", "/tmp/a script.sh")
        self.assertEqual(command[:2], ["xfce4-terminal", "--command"])
        self.assertEqual(command[2], "bash '/tmp/a script.sh'")

    def test_unknown_terminal_is_rejected(self):
        with self.assertRaises(ValueError):
            terminal.build_terminal_command("unknown", "/tmp/example.sh")

    def test_validated_target_must_be_direct_child_of_script_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "日本語 script.sh"
            script.write_text("#!/bin/bash\n", encoding="utf-8")
            self.assertEqual(
                terminal.validate_target_path(str(script), directory), str(script)
            )

            nested = Path(directory) / "nested"
            nested.mkdir()
            nested_script = nested / "blocked.sh"
            nested_script.write_text("#!/bin/bash\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                terminal.validate_target_path(str(nested_script), directory)

    def test_validated_target_rejects_symlink_escape(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            external_script = Path(outside) / "external.sh"
            external_script.write_text("#!/bin/bash\n", encoding="utf-8")
            link = Path(directory) / "link.sh"
            link.symlink_to(external_script)
            with self.assertRaises(ValueError):
                terminal.validate_target_path(str(link), directory)


if __name__ == "__main__":
    unittest.main()
