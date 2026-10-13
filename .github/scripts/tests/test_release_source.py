import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release


class ReleaseSourceTests(unittest.TestCase):
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
        self.git("init", "--initial-branch=master")
        self.git("commit", "--allow-empty", "-m", "initial")
        self.initial = self.git("rev-parse", "HEAD")
        self.git("switch", "-c", "dev")
        self.git("commit", "--allow-empty", "-m", "development")
        self.dev = self.git("rev-parse", "HEAD")
        self.git("switch", "master")
        self.git("commit", "--allow-empty", "-m", "stable")
        self.master = self.git("rev-parse", "HEAD")
        self.git("update-ref", "refs/remotes/origin/master", self.master)
        self.tag_env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": "v0.1.1"}

    def git(self, *args):
        result = subprocess.run(
            ["git", *args], cwd=self.root, env=self.git_env,
            capture_output=True, text=True, check=True, timeout=30,
        )
        return result.stdout.strip()

    def test_current_master_and_older_master_commit_are_allowed(self):
        for commit in (self.master, self.initial):
            with self.subTest(commit=commit):
                self.git("checkout", "--detach", commit)
                self.assertEqual(release.validate_source(self.root, self.tag_env), commit)

    def test_development_commit_rejected_until_merged_into_master(self):
        self.git("switch", "dev")
        with self.assertRaisesRegex(ValueError, "尚未合入 master"):
            release.validate_source(self.root, self.tag_env)
        self.git("switch", "master")
        self.git("merge", "--no-ff", "dev", "-m", "merge development")
        self.git("update-ref", "refs/remotes/origin/master", "HEAD")
        self.git("checkout", "--detach", self.dev)
        self.assertEqual(release.validate_source(self.root, self.tag_env), self.dev)

    def test_missing_master_is_rejected(self):
        self.git("update-ref", "-d", "refs/remotes/origin/master")
        with self.assertRaisesRegex(ValueError, "无法找到远端 master"):
            release.validate_source(self.root, self.tag_env)

    def test_manual_build_requires_master_branch(self):
        env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF_TYPE": "branch", "GITHUB_REF_NAME": "master"}
        self.assertEqual(release.validate_source(self.root, env), self.master)
        for ref_type, name in (("branch", "dev"), ("branch", "main"), ("tag", "v0.1.1")):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "必须选择 master"):
                release.validate_source(self.root, {**env, "GITHUB_REF_TYPE": ref_type, "GITHUB_REF_NAME": name})

    def test_lightweight_and_annotated_tags_use_peeled_commit(self):
        self.git("tag", "lightweight", self.initial)
        self.git("tag", "-a", "annotated", self.initial, "-m", "annotated version")
        for tag in ("lightweight", "annotated"):
            with self.subTest(tag=tag):
                self.git("checkout", "--detach", tag)
                env = {**self.tag_env, "GITHUB_SHA": self.git("rev-parse", tag)}
                self.assertEqual(release.validate_source(self.root, env), self.initial)

    def test_metadata_entry_point_blocks_dev_before_exposing_build_outputs(self):
        script = self.root / ".github/scripts/release.py"
        script.parent.mkdir(parents=True)
        shutil.copyfile(release.__file__, script)
        (self.root / "pubspec.yaml").write_text("version: 0.1.1+2\n", encoding="utf-8")
        for commit, expected in ((self.dev, 1), (self.master, 0)):
            with self.subTest(commit=commit):
                self.git("checkout", "--detach", commit)
                result = subprocess.run(
                    [sys.executable, str(script), "metadata"], cwd=self.root,
                    env={**self.git_env, **self.tag_env, "PYTHONUTF8": "1", "GITHUB_OUTPUT": ""},
                    capture_output=True, text=True, encoding="utf-8", timeout=30,
                )
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                if expected:
                    self.assertIn("尚未合入 master", result.stderr)
                    self.assertEqual(result.stdout, "")
                else:
                    self.assertIn('"version": "0.1.1"', result.stdout)


if __name__ == "__main__":
    unittest.main()
