import base64
import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release


class FakeGitHub:
    def __init__(self, existing=None, sha="commit-sha", fail_upload=False):
        self.existing = existing
        self.sha = sha
        self.fail_upload = fail_upload
        self.calls = []
        self.created = None

    def request(self, method, path, payload=None, file=None):
        self.calls.append((method, path, payload, file))
        if "/git/ref/" in path:
            return {"object": {"type": "commit", "sha": self.sha}}
        if method == "GET" and "/releases/tags/" in path:
            return self.existing
        if path.endswith("generate-notes"):
            return {"body": "修复阅读与段评问题"}
        if method == "POST" and path.endswith("/releases"):
            self.created = payload
            return {"draft": True, "upload_url": "https://uploads.github.com/repos/owner/unr/releases/1/assets{?name,label}", "html_url": "https://github.com/owner/unr/releases/tag/v0.1.1", "assets": []}
        if file is not None and self.fail_upload:
            raise RuntimeError("模拟上传断线")
        return None


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "pubspec.yaml").write_text("name: unr\nversion: 0.1.1+2\n", encoding="utf-8")
        (self.root / "LICENSE").write_text("test-license", encoding="utf-8")
        (self.root / "README.md").write_text("# 开源库\n", encoding="utf-8")
        self.env = {"RELEASE_VERSION": "0.1.1", "GITHUB_EVENT_NAME": "push", "GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": "v0.1.1", "GITHUB_REPOSITORY": "owner/unr", "GITHUB_SHA": "commit-sha", "GH_TOKEN": "synthetic-token"}

    def bundle(self):
        source = self.root / "build/windows/x64/runner/Release"
        for name in ["unr.exe", "flutter_windows.dll", "plugin.dll", "data/app.so", "data/icudtl.dat", "data/flutter_assets/assets/sfacg_cipher.json"]:
            file = source / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b"synthetic-binary")
        return source

    def apk(self, file, abis):
        file.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(file, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"synthetic-manifest")
            for abi in abis:
                archive.writestr(f"lib/{abi}/libapp.so", b"synthetic-native-library")

    def assets(self):
        self.bundle()
        release.windows(self.root, "0.1.1")
        self.apk(self.root / "build/release/unr-0.1.1-android-universal.apk", release.ABIS)
        for abi in release.ABIS:
            self.apk(self.root / f"build/app/outputs/flutter-apk/app-{abi}-release.apk", [abi])
        release.android(self.root, "0.1.1")

    def test_stable_tag_matches_pubspec_and_manual_run_does_not_change_version(self):
        expected = {"version": "0.1.1", "build_number": "2", "prerelease": "false"}
        self.assertEqual(release.metadata(self.root, self.env), expected)
        self.assertEqual(release.metadata(self.root, {"GITHUB_REF_TYPE": "branch", "GITHUB_REF_NAME": "dev"}), expected)
        with self.assertRaisesRegex(ValueError, "标签必须"):
            release.metadata(self.root, {**self.env, "GITHUB_REF_NAME": "v0.1.2"})

    def test_prerelease_and_invalid_versions(self):
        (self.root / "pubspec.yaml").write_text("version: '0.1.2-rc.1+3'\n", encoding="utf-8")
        self.assertEqual(release.metadata(self.root, {**self.env, "GITHUB_REF_NAME": "v0.1.2-rc.1"})["prerelease"], "true")
        for version in ("../0.1.1", "00.1.1", "1.2.3-rc..1", "1.2.3-01", "65536.1.1", "1.2.3\nINJECTED=1"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                release.validate_version(version)
        for value in ("0.1.1", "0.1.1+0", "0.1.1+65536", "0.1.1+password"):
            (self.root / "pubspec.yaml").write_text(f"version: {value}\n", encoding="utf-8")
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.metadata(self.root, {})

    def test_metadata_output_has_plain_key_value_records(self):
        file = self.root / "output"
        release.output(release.metadata(self.root, self.env), {"GITHUB_OUTPUT": str(file)})
        self.assertEqual(file.read_text(encoding="utf-8"), "version=0.1.1\nbuild_number=2\nprerelease=false\n")

    def test_signing_requires_all_secrets_without_leaking_values_and_cleans_only_key(self):
        env = {"RUNNER_TEMP": str(self.root), "KEYSTORE_BASE64": base64.b64encode(b"synthetic-keystore").decode(), "KEYSTORE_PASSWORD": "synthetic-store-password", "KEY_PASSWORD": "synthetic-key-password", "KEY_ALIAS": "test-alias"}
        with self.assertRaisesRegex(ValueError, "KEY_ALIAS") as error:
            release.signing({**env, "KEY_ALIAS": ""})
        self.assertNotIn("synthetic-store-password", str(error.exception))
        path = Path(release.signing(env)["keystore_path"])
        self.assertEqual(path.read_bytes(), b"synthetic-keystore")
        keep = path.parent / "keep"
        keep.write_text("keep", encoding="utf-8")
        release.clean_signing(env)
        release.clean_signing(env)
        self.assertFalse(path.exists())
        self.assertTrue(keep.exists())
        with self.assertRaisesRegex(ValueError, "Base64"):
            release.signing({**env, "KEYSTORE_BASE64": "not$base64"})

    def test_windows_bundle_contains_runtime_plugins_data_and_licenses_at_root(self):
        self.bundle()
        path = release.windows(self.root, "0.1.1")
        with zipfile.ZipFile(path) as archive:
            self.assertIn("unr.exe", archive.namelist())
            self.assertIn("plugin.dll", archive.namelist())
            self.assertIn("data/flutter_assets/assets/sfacg_cipher.json", archive.namelist())
            self.assertEqual(archive.read("LICENSE"), b"test-license")
            self.assertIn("README.md", archive.namelist())
        (self.root / "build/windows/x64/runner/Release/flutter_windows.dll").unlink()
        with self.assertRaisesRegex(FileNotFoundError, "flutter_windows.dll"):
            release.windows(self.root, "0.1.1")

    def test_apks_preserve_universal_and_cover_all_three_abis(self):
        self.assets()
        self.assertEqual(len(list((self.root / "build/release").glob("*.apk"))), 4)
        with zipfile.ZipFile(self.root / "build/release/unr-0.1.1-android-universal.apk") as archive:
            for abi in release.ABIS:
                self.assertIn(f"lib/{abi}/libapp.so", archive.namelist())

    def test_finalize_requires_complete_same_version_assets_and_validates_checksums(self):
        self.assets()
        files = release.finalize(self.root, "0.1.1")
        self.assertEqual(len(files), 7)
        records = (self.root / "build/release/SHA256SUMS").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(records), 6)
        for line in records:
            digest, name = line.split("  ")
            self.assertEqual(digest, hashlib.sha256((self.root / "build/release" / name).read_bytes()).hexdigest())
        (self.root / "build/release/unr-0.1.1-android-arm64-v8a.apk").rename(self.root / "build/release/unr-0.1.2-android-arm64-v8a.apk")
        with self.assertRaisesRegex(ValueError, "版本混杂"):
            release.finalize(self.root, "0.1.1")

    def test_wrong_architecture_or_missing_android_manifest_rejected(self):
        self.assets()
        self.apk(self.root / "build/release/unr-0.1.1-android-arm64-v8a.apk", ["x86_64"])
        with self.assertRaisesRegex(ValueError, "内容不完整"):
            release.finalize(self.root, "0.1.1")

    def test_new_release_remains_draft_after_all_uploads(self):
        self.assets()
        api = FakeGitHub()
        release.draft(self.root, self.env, api)
        self.assertTrue(api.created["draft"])
        self.assertFalse(api.created["prerelease"])
        self.assertIn("AGPL-3.0", api.created["body"])
        self.assertEqual(len([call for call in api.calls if call[3] is not None]), 7)
        self.assertFalse(any(call[0] == "PATCH" for call in api.calls))

    def test_upload_failure_never_publishes_partial_release(self):
        self.assets()
        api = FakeGitHub(fail_upload=True)
        with self.assertRaisesRegex(RuntimeError, "上传断线"):
            release.draft(self.root, self.env, api)
        self.assertTrue(api.created["draft"])
        self.assertFalse(any(call[0] == "PATCH" for call in api.calls))

    def test_rerun_reuses_draft_only_replaces_matching_asset_and_preserves_notes(self):
        self.assets()
        existing = {"draft": True, "body": "维护者手写说明", "html_url": "https://github.com/owner/unr/releases/tag/v0.1.1", "upload_url": "https://uploads.github.com/repos/owner/unr/releases/1/assets{?name,label}", "assets": [{"id": 10, "name": "unr-0.1.1-windows-x64.zip"}, {"id": 11, "name": "manual-screenshot.png"}]}
        api = FakeGitHub(existing=existing)
        release.draft(self.root, self.env, api)
        self.assertIsNone(api.created)
        self.assertEqual(existing["body"], "维护者手写说明")
        self.assertEqual([call[1] for call in api.calls if call[0] == "DELETE"], ["/repos/owner/unr/releases/assets/10"])
        self.assertFalse(any(call[0] == "PATCH" for call in api.calls))

    def test_published_release_moved_tag_and_manual_runs_never_modify_release(self):
        for env, api, expected in [
            (self.env, FakeGitHub(existing={"draft": False}), "已经发布"),
            (self.env, FakeGitHub(sha="different-commit"), "其他提交"),
            ({**self.env, "GITHUB_EVENT_NAME": "workflow_dispatch"}, FakeGitHub(), "手动运行"),
        ]:
            with self.subTest(expected=expected), self.assertRaisesRegex(ValueError, expected):
                release.draft(self.root, env, api)
            self.assertTrue(all(call[0] == "GET" for call in api.calls))

    def test_annotated_tag_resolves_to_checked_out_commit(self):
        self.assets()
        api = FakeGitHub()
        original_request = api.request

        def request(method, path, payload=None, file=None):
            if "/git/ref/" in path:
                return {"object": {"type": "tag", "sha": "tag-object-sha"}}
            if "/git/tags/" in path:
                return {"object": {"type": "commit", "sha": "commit-sha"}}
            return original_request(method, path, payload, file)

        api.request = request
        release.draft(self.root, self.env, api)
        self.assertEqual(api.created["target_commitish"], "commit-sha")

    def test_github_404_is_only_accepted_for_reads_and_permission_errors_fail(self):
        api = release.GitHub(self.env)
        for method, status in [("GET", 404), ("POST", 404), ("GET", 403)]:
            error = urllib.error.HTTPError("https://api.github.com/test", status, "test", {}, io.BytesIO(b"{}"))
            with patch("urllib.request.urlopen", side_effect=error):
                if (method, status) == ("GET", 404):
                    self.assertIsNone(api.request(method, "/test"))
                else:
                    with self.assertRaisesRegex(RuntimeError, f"HTTP {status}"):
                        api.request(method, "/test")


if __name__ == "__main__":
    unittest.main()
