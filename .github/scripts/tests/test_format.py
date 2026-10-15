import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_format


class FormatTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.git_env = {
            **os.environ,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_AUTHOR_NAME": "CI Test",
            "GIT_AUTHOR_EMAIL": "ci@example.invalid",
            "GIT_COMMITTER_NAME": "CI Test",
            "GIT_COMMITTER_EMAIL": "ci@example.invalid",
        }
        self.git("init", "--initial-branch=dev")
        self.write("keep.dart", "void main() {}\n")
        self.write("remove.dart", "void main() {}\n")
        self.write(".gitignore", "ignored.dart\n")
        self.commit()
        self.base = self.git("rev-parse", "HEAD")

    def git(self, *args):
        return subprocess.check_output(
            ["git", *args], cwd=self.root, env=self.git_env, text=True, encoding="utf-8", timeout=30,
        ).strip()

    def write(self, name, text):
        (self.root / name).write_text(text, encoding="utf-8")

    def commit(self):
        self.git("add", "--all")
        self.git("commit", "-m", "test fixture")

    def test_changed_files_include_renames_and_unusual_names_but_skip_deletions(self):
        self.write("keep.dart", "void main() { print(1); }\n")
        (self.root / "remove.dart").unlink()
        self.write("name with spaces;$(noop).dart", "void main() {}\n")
        self.commit()
        self.assertEqual(check_format.selected_files(self.root, self.base), ["keep.dart", "name with spaces;$(noop).dart"])

    def test_zero_or_missing_base_checks_tracked_files_only(self):
        self.write("ignored.dart", "not Dart")
        self.write("untracked.dart", "not Dart")
        for base in (None, "0" * 40):
            with self.subTest(base=base):
                self.assertEqual(check_format.selected_files(self.root, base), [".gitignore", "keep.dart", "remove.dart"])

    def test_invalid_or_missing_commit_fails_instead_of_skipping_checks(self):
        with self.assertRaises(ValueError):
            check_format.selected_files(self.root, "--output=elsewhere")
        with self.assertRaises(subprocess.CalledProcessError):
            check_format.selected_files(self.root, "a" * 40)

    def test_invalid_json_and_python_fail_without_rewriting_files(self):
        for name, content in (("bad.json", "{broken"), ("bad.py", "def broken(\n")):
            with self.subTest(name=name):
                self.write(name, content)
                with self.assertRaises((ValueError, SyntaxError)):
                    check_format.check_files(self.root, [name])
                self.assertEqual((self.root / name).read_text(encoding="utf-8"), content)

    def test_formatter_failure_propagates_and_filenames_never_go_through_shell(self):
        name = "name with spaces;$(noop).dart"
        self.write(name, "void main(){}\n")
        with patch.object(check_format, "dart_executable", return_value="dart-sdk"), patch.object(
            check_format.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "dart format"),
        ) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                check_format.check_files(self.root, [name])
            args, kwargs = run.call_args
            self.assertEqual(args[0], ["dart-sdk", "format", "--output=none", "--set-exit-if-changed", "--", name])
            self.assertNotIn("shell", kwargs)
        self.assertEqual((self.root / name).read_text(encoding="utf-8"), "void main(){}\n")

    def test_windows_dart_batch_wrapper_resolves_to_native_sdk(self):
        wrapper = self.root / "bin/dart.bat"
        executable = self.root / "bin/cache/dart-sdk/bin/dart.exe"
        executable.parent.mkdir(parents=True)
        executable.touch()
        with patch.object(check_format.shutil, "which", return_value=str(wrapper)):
            self.assertEqual(check_format.dart_executable(), str(executable))

    def test_fix_mode_formats_dart_and_preserves_other_files(self):
        self.write("keep.dart", "void main(){}\n")
        self.write("data.json", '{"value":1}\n')
        self.write("example.py", "value=1\n")
        with patch.object(check_format, "dart_executable", return_value="dart-sdk"), patch.object(
            check_format.subprocess, "run",
        ) as run:
            check_format.check_files(self.root, ["keep.dart", "data.json", "example.py"], fix=True)
            args, kwargs = run.call_args
            self.assertEqual(args[0], ["dart-sdk", "format", "--output=write", "--", "keep.dart"])
            self.assertNotIn("shell", kwargs)
        self.assertEqual((self.root / "data.json").read_text(encoding="utf-8"), '{"value":1}\n')
        self.assertEqual((self.root / "example.py").read_text(encoding="utf-8"), "value=1\n")

    def test_fix_mode_stops_before_formatting_when_json_is_invalid(self):
        self.write("bad.json", "{broken")
        with patch.object(check_format, "dart_executable") as executable:
            with self.assertRaises(ValueError):
                check_format.check_files(self.root, ["keep.dart", "bad.json"], fix=True)
            executable.assert_not_called()


if __name__ == "__main__":
    unittest.main()
