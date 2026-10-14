from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release


class ChangelogTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.file = self.root / "CHANGELOG.md"

    def write(self, text):
        self.file.write_text(text, encoding="utf-8")

    def test_current_version_excludes_historical_notes_and_keeps_unicode_links(self):
        current = "## v0.3.0\n\n### 新增 | New\n\n* 支持平台书架导入 ([#12](https://github.com/owner/unr/pull/12)) @author\n"
        self.write("\ufeff# 更新日志\n\n" + current + "\n## v0.2.0\n\n* 旧功能。\n")
        self.assertEqual(release.changelog(self.root, "0.3.0"), current.strip())

    def test_prerelease_and_windows_newlines_are_supported(self):
        self.file.write_bytes("# 更新日志\r\n\r\n## v0.3.0-rc.1\r\n\r\n* 修复目录。\r\n".encode("utf-8"))
        self.assertIn("修复目录", release.changelog(self.root, "0.3.0-rc.1"))

    def test_missing_mismatched_duplicate_empty_and_placeholder_notes_fail(self):
        with self.assertRaisesRegex(ValueError, "缺少已提交"):
            release.changelog(self.root, "0.3.0")
        for text in (
            "## v0.2.0\n* 旧内容\n",
            "## v0.3.0\n* 内容\n## v0.3.0\n* 重复\n",
            "## v0.3.0\n### 新增 | New\n",
            "## v0.3.0\n* TODO: 补充\n",
            "## v0.3.0\n* 待补充\n",
            "## v0.3.0\n* 内容\n## 自定义分类\n* 其他\n",
            "## v0.3.0\n* 内容\n## v0.2.0+2\n* 错误构建号\n",
        ):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.write(text)
                release.changelog(self.root, "0.3.0")

    def test_code_examples_are_not_release_boundaries_or_reviewed_bullets(self):
        self.write("## v0.3.0\n* 修复阅读\n```md\n## v0.1.0\n* 示例\n```\n## v0.2.0\n* 旧内容\n")
        notes = release.changelog(self.root, "0.3.0")
        self.assertIn("## v0.1.0", notes)
        self.assertNotIn("旧内容", notes)
        for text in ("```md\n## v0.3.0\n* 示例\n```\n", "## v0.3.0\n```md\n* 示例\n```\n", "## v0.3.0\n* 内容\n```md\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.write(text)
                release.changelog(self.root, "0.3.0")

    def test_preparation_cli_requires_no_master_ancestry_and_uses_pubspec_version(self):
        (self.root / "pubspec.yaml").write_text("version: 0.3.0+4\n", encoding="utf-8")
        self.write("## v0.3.0\n* 新功能\n")
        script = self.root / ".github/scripts/release.py"
        script.parent.mkdir(parents=True)
        shutil.copyfile(release.__file__, script)
        env = {**os.environ, "PYTHONUTF8": "1", "GITHUB_REF_TYPE": "branch", "GITHUB_REF_NAME": "dev"}
        result = subprocess.run([sys.executable, str(script), "changelog"], cwd=self.root, env=env, capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("v0.3.0 更新日志校验通过", result.stdout)
        (self.root / "pubspec.yaml").write_text("version: 0.3.1+5\n", encoding="utf-8")
        result = subprocess.run([sys.executable, str(script), "changelog"], cwd=self.root, env=env, capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
