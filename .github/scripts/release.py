"""UNR release metadata, packaging and draft upload; standard library only."""

import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile


ABIS = ("armeabi-v7a", "arm64-v8a", "x86_64")
VERSION = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?")


def validate_version(version):
    match = VERSION.fullmatch(version)
    if not match or any(int(part) > 65535 for part in match.groups()[:3]):
        raise ValueError("版本格式应为 X.Y.Z 或 X.Y.Z-rc.N，数字不能超过 65535")
    if match[4]:
        for identifier in match[4].split("."):
            if not identifier or (identifier.isdigit() and len(identifier) > 1 and identifier[0] == "0"):
                raise ValueError("预发布版本标识无效")
    return version


def metadata(root, env):
    text = (root / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*['\"]?([^\s'\"#]+)", text, re.MULTILINE)
    if not match or "+" not in match[1]:
        raise ValueError("pubspec.yaml 必须设置 version: X.Y.Z+构建号")
    version, number = match[1].rsplit("+", 1)
    validate_version(version)
    if not number.isdigit() or not 1 <= int(number) <= 65535:
        raise ValueError("构建号应为 1 到 65535 的整数（兼容 Android 和 Windows）")
    if env.get("GITHUB_REF_TYPE") == "tag" and env.get("GITHUB_REF_NAME") != f"v{version}":
        raise ValueError(f"标签必须与 pubspec.yaml 一致：应为 v{version}")
    return {"version": version, "build_number": str(int(number)), "prerelease": str("-" in version).lower()}


def output(values, env):
    if env.get("GITHUB_OUTPUT"):
        with Path(env["GITHUB_OUTPUT"]).open("a", encoding="utf-8", newline="\n") as handle:
            for key, value in values.items():
                handle.write(f"{key}={value}\n")
    else:
        print(json.dumps(values, ensure_ascii=False))


def signing(env):
    required = ("KEYSTORE_BASE64", "KEYSTORE_PASSWORD", "KEY_PASSWORD", "KEY_ALIAS")
    missing = [name for name in required if not env.get(name)]
    if missing:
        raise ValueError("缺少仓库 Secrets：" + ", ".join(missing))
    try:
        data = base64.b64decode("".join(env["KEYSTORE_BASE64"].split()), validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("KEYSTORE_BASE64 不是有效的 Base64 密钥文件") from error
    if not data:
        raise ValueError("签名密钥文件为空")
    destination = Path(env["RUNNER_TEMP"]) / "unr-signing" / "release.jks"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as handle:
        handle.write(data)
    destination.chmod(0o600)
    return {"keystore_path": str(destination.resolve())}


def clean_signing(env):
    (Path(env["RUNNER_TEMP"]) / "unr-signing" / "release.jks").unlink(missing_ok=True)


def checkout_commit(root):
    # An annotated tag's event SHA can name a tag object. The checked-out HEAD
    # always identifies the commit whose sources all build jobs actually used.
    result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True, check=True)
    value = result.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", value):
        raise ValueError("无法确认当前构建的 Git 提交")
    return value


def release_directory(root):
    destination = root / "build" / "release"
    destination.mkdir(parents=True, exist_ok=True)
    return destination


def asset_names(version):
    validate_version(version)
    return [f"unr-{version}-windows-x64.zip", *[
        f"unr-{version}-android-{abi}.apk" for abi in ("universal", *ABIS)
    ]]


def windows(root, version):
    validate_version(version)
    source = root / "build/windows/x64/runner/Release"
    required = ("unr.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat")
    for relative in required:
        if not (source / relative).is_file():
            raise FileNotFoundError(f"Windows 构建缺少 {relative}")
    if not (source / "data/flutter_assets").is_dir():
        raise FileNotFoundError("Windows 构建缺少 Flutter 资源目录")
    destination = release_directory(root) / asset_names(version)[0]
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(source.rglob("*")):
            if file.is_symlink():
                raise ValueError("Windows 构建目录中不应含符号链接")
            if file.is_file():
                archive.write(file, file.relative_to(source).as_posix())
        for name in ("LICENSE", "README.md"):
            archive.write(root / name, name)
    return destination


def android(root, version):
    validate_version(version)
    source = root / "build/app/outputs/flutter-apk"
    destination = release_directory(root)
    universal = destination / f"unr-{version}-android-universal.apk"
    if not universal.is_file():
        raise FileNotFoundError("通用 APK 必须在分 ABI 构建前另存")
    for abi in ABIS:
        shutil.copyfile(source / f"app-{abi}-release.apk", destination / f"unr-{version}-android-{abi}.apk")


def validate_assets(root, version):
    destination = release_directory(root)
    names = asset_names(version)
    actual = {file.name for file in destination.iterdir() if file.suffix in (".apk", ".zip")}
    if actual != set(names):
        raise ValueError(f"发布附件不完整或版本混杂，应为：{', '.join(names)}")
    for name in names:
        file = destination / name
        if not file.is_file() or file.stat().st_size == 0:
            raise ValueError(f"发布附件为空：{name}")
        with zipfile.ZipFile(file) as archive:
            entries = set(archive.namelist())
            if name.endswith(".zip"):
                required = {"unr.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat", "LICENSE", "README.md"}
            else:
                abis = ABIS if name.endswith("universal.apk") else (next(abi for abi in ABIS if name.endswith(f"{abi}.apk")),)
                required = {"AndroidManifest.xml", *[f"lib/{abi}/libapp.so" for abi in abis]}
            if not required <= entries or archive.testzip() is not None:
                raise ValueError(f"发布附件内容不完整：{name}")
    return [destination / name for name in names]


def finalize(root, version):
    files = validate_assets(root, version)
    destination = release_directory(root)
    license_file = destination / "LICENSE"
    shutil.copyfile(root / "LICENSE", license_file)
    files.append(license_file)
    checksums = destination / "SHA256SUMS"
    with checksums.open("w", encoding="utf-8", newline="\n") as handle:
        for file in files:
            with file.open("rb") as data:
                digest = hashlib.file_digest(data, "sha256").hexdigest()
            handle.write(f"{digest}  {file.name}\n")
    return [*files, checksums]


class GitHub:
    def __init__(self, env):
        self.token = env["GH_TOKEN"]
        self.base = env.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")

    def request(self, method, path, payload=None, file=None):
        url = path if path.startswith("https://") else f"{self.base}{path}"
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json", "User-Agent": "UNR-release-ci"}
        data = None
        if file is not None:
            data = file.read_bytes()
            headers["Content-Type"] = "application/octet-stream"
        elif payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                body = response.read()
                return json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            if error.code == 404 and method == "GET":
                return None
            raise RuntimeError(f"GitHub {method} 请求失败（HTTP {error.code}），请检查 Actions 权限或运行记录") from error
        except urllib.error.URLError as error:
            raise RuntimeError("GitHub 连接失败；若草稿已经创建，可重跑此工作流继续上传") from error


def draft(root, env, api):
    version = validate_version(env["RELEASE_VERSION"])
    tag = f"v{version}"
    if env.get("GITHUB_EVENT_NAME") != "push" or env.get("GITHUB_REF_TYPE") != "tag" or env.get("GITHUB_REF_NAME") != tag:
        raise ValueError("只有推送匹配的版本标签才能创建 Release；手动运行只构建")
    repo = env["GITHUB_REPOSITORY"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("仓库名称无效")
    prefix = f"/repos/{repo}"
    # A tag moved while builds were running must not receive the old binaries.
    reference = api.request("GET", f"{prefix}/git/ref/tags/{tag}")
    if reference is None:
        raise ValueError("版本标签不存在")
    target = reference["object"]
    for _ in range(10):
        if target["type"] != "tag":
            break
        target = api.request("GET", f"{prefix}/git/tags/{target['sha']}")["object"]
    if target["type"] != "commit" or target["sha"] != env["GITHUB_SHA"]:
        raise ValueError("版本标签已指向其他提交，停止上传以免混用版本")
    existing = api.request("GET", f"{prefix}/releases/tags/{tag}")
    if existing is not None and not existing["draft"]:
        raise ValueError("该版本已经发布，不会覆盖附件；请增加版本号和构建号")
    files = finalize(root, version)
    if existing is None:
        notes = api.request("POST", f"{prefix}/releases/generate-notes", {"tag_name": tag, "target_commitish": env["GITHUB_SHA"]})
        server = env.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
        links = "\n".join(f"- [{file.name}]({server}/{repo}/releases/download/{tag}/{file.name})" for file in files)
        body = (
            f"UNR {version}\n\n{links}\n\n"
            "Android 通常选择 arm64-v8a；不确定时下载 universal。Windows 解压完整 ZIP 后运行 unr.exe，勿单独移动 EXE。\n\n"
            "Windows 如果提示缺少 VCRUNTIME/MSVCP DLL，请安装[微软官方 Visual C++ x64 运行库](https://aka.ms/vc14/vc_redist.x64.exe)。\n\n"
            "Windows 未配置代码签名；系统可能提示未知发布者。\n\n"
            f"源码与构建流程：[{tag}]({server}/{repo}/tree/{tag})，项目使用 AGPL-3.0。\n\n"
            f"{notes.get('body', '')}\n"
        )
        existing = api.request("POST", f"{prefix}/releases", {"tag_name": tag, "target_commitish": env["GITHUB_SHA"], "name": f"UNR {version}", "body": body, "draft": True, "prerelease": "-" in version})
    upload = existing["upload_url"].split("{", 1)[0]
    if not upload.startswith("https://uploads.github.com/"):
        raise ValueError("Release 上传地址无效")
    # Replace only our own named assets in a draft; preserve manually edited notes.
    for file in files:
        for asset in existing.get("assets", []):
            if asset["name"] == file.name:
                api.request("DELETE", f"{prefix}/releases/assets/{asset['id']}")
        api.request("POST", f"{upload}?name={urllib.parse.quote(file.name)}", file=file)
    print(f"Release 草稿已就绪：{existing['html_url']}；检查附件后点击 Publish release。")


def main():
    root = Path(__file__).resolve().parents[2]
    env = os.environ
    command = sys.argv[1] if len(sys.argv) == 2 else ""
    if command == "metadata":
        output(metadata(root, env), env)
    elif command == "signing":
        output(signing(env), env)
    elif command == "clean-signing":
        clean_signing(env)
    elif command in ("windows", "android", "finalize"):
        globals()[command](root, env["RELEASE_VERSION"])
    elif command == "draft":
        env = {**env, "GITHUB_SHA": checkout_commit(root)}
        draft(root, env, GitHub(env))
    else:
        raise ValueError("使用 metadata / signing / clean-signing / windows / android / finalize / draft")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Release 失败：{error}", file=sys.stderr)
        sys.exit(1)
