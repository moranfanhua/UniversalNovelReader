"""Check tracked files, optionally applying Dart formatting with --fix."""

import argparse
import ast
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def selected_files(root, base=None):
    if base and base != "0" * 40:
        if not re.fullmatch(r"[0-9a-fA-F]{40}", base):
            raise ValueError("格式检查的基准必须是完整 commit SHA")
        command = ["git", "diff", "--name-only", "--diff-filter=ACMR", "-z", base, "HEAD", "--"]
    else:
        command = ["git", "ls-files", "-z"]
    output = subprocess.check_output(command, cwd=root)
    return sorted({
        path for path in output.decode("utf-8").split("\0")
        if path and (root / path).is_file()
    })


def dart_executable():
    executable = shutil.which("dart")
    if not executable:
        raise ValueError("找不到 Dart SDK，请先安装项目指定的 Flutter")
    if Path(executable).suffix.lower() in (".bat", ".cmd"):
        # 直接调用 SDK，避免 Windows batch shell 解释来自 PR 的文件名。
        executable = Path(executable).parent / "cache/dart-sdk/bin/dart.exe"
        if not executable.is_file():
            raise ValueError("找不到 Flutter 内的 dart.exe")
    return str(executable)


def check_files(root, paths, fix=False):
    for path in paths:
        file = root / path
        if file.suffix == ".json":
            with file.open(encoding="utf-8") as handle:
                json.load(handle)
        elif file.suffix == ".py":
            ast.parse(file.read_text(encoding="utf-8"), filename=path)
    dart_files = [path for path in paths if Path(path).suffix == ".dart"]
    if dart_files:
        executable = dart_executable()
        format_options = ["--output=write"] if fix else ["--output=none", "--set-exit-if-changed"]
        for start in range(0, len(dart_files), 40):
            subprocess.run(
                [executable, "format", *format_options, "--", *dart_files[start:start + 40]],
                cwd=root, check=True,
            )
    result = "已应用 Dart 格式化" if fix else "未修改文件"
    print(f"已检查 {len(paths)} 个文件，其中 {len(dart_files)} 个 Dart 文件；{result}。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=os.environ.get("FORMAT_BASE_SHA"))
    parser.add_argument("--fix", action="store_true", help="应用 Dart 格式化，默认仅检查")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    try:
        paths = selected_files(root, args.base)
        revision = [args.base, "HEAD"] if args.base and args.base != "0" * 40 else ["HEAD"]
        if not args.fix:
            subprocess.run(["git", "diff", "--check", *revision, "--"], cwd=root, check=True)
        check_files(root, paths, fix=args.fix)
        if args.fix:
            subprocess.run(["git", "diff", "--check", "HEAD", "--"], cwd=root, check=True)
    except (ValueError, SyntaxError, OSError, subprocess.CalledProcessError) as error:
        print(f"格式检查失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
