"""Check tracked files, optionally applying Dart formatting with --fix."""

import argparse
import ast
import difflib
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


def diagnostic(path, message, line=None, end_line=None):
    return {"path": path, "message": message, "line": line, "end_line": end_line or line}


def changed_line_diagnostics(path, original, formatted):
    lines = original.splitlines(keepends=True)
    result = []
    for tag, start, end, _, _ in difflib.SequenceMatcher(
        None, lines, formatted.splitlines(keepends=True), autojunk=False,
    ).get_opcodes():
        if tag != "equal":
            line = min(start + 1, max(1, len(lines)))
            result.append(diagnostic(path, "Dart 格式不符合规范，请运行 dart format。", line, max(line, end)))
    return result


def collect_diagnostics(root, paths, base=None):
    diagnostics = []
    revision = [base, "HEAD"] if base and base != "0" * 40 else ["HEAD"]
    whitespace = subprocess.run(
        ["git", "-c", "core.quotePath=false", "diff", "--check", *revision, "--"],
        cwd=root, capture_output=True, text=True, encoding="utf-8", check=False,
    )
    for match in re.finditer(r"^(.+):(\d+): (.+)$", whitespace.stdout, re.MULTILINE):
        path, line, message = match.groups()
        if path.startswith('"'):
            path = ast.literal_eval(path)
        diagnostics.append(diagnostic(path, message, int(line)))
    if whitespace.returncode and not diagnostics:
        diagnostics.append(diagnostic(None, "无法完成 Git 空白检查，详见工作流日志。"))
        print(whitespace.stdout + whitespace.stderr, file=sys.stderr)

    for path in paths:
        try:
            if Path(path).suffix == ".json":
                json.loads((root / path).read_text(encoding="utf-8"))
            elif Path(path).suffix == ".py":
                ast.parse((root / path).read_text(encoding="utf-8"), filename=path)
        except (json.JSONDecodeError, SyntaxError) as error:
            diagnostics.append(diagnostic(path, error.msg, error.lineno))

    dart_files = [path for path in paths if Path(path).suffix == ".dart"]
    if not dart_files:
        return diagnostics
    executable = dart_executable()
    for start in range(0, len(dart_files), 40):
        batch = dart_files[start:start + 40]
        result = subprocess.run(
            [executable, "format", "--output=json", "--show=none", "--summary=none", "--", *batch],
            cwd=root, capture_output=True, text=True, encoding="utf-8", check=False,
        )
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        formatted = {}
        for output in result.stdout.splitlines():
            item = json.loads(output)
            if item.get("path") not in batch or not isinstance(item.get("source"), str):
                raise ValueError("Dart 格式化输出包含不匹配的文件或内容")
            formatted[item["path"]] = item["source"].replace("\r\n", "\n")
        parse_errors = set()
        for match in re.finditer(r"^line (\d+), column \d+ of (.+)$", result.stderr, re.MULTILINE):
            line, detail = match.groups()
            for path in batch:
                if detail.startswith(path + ": "):
                    diagnostics.append(diagnostic(path, detail[len(path) + 2:], int(line)))
                    parse_errors.add(path)
                    break
        for path in batch:
            if path in formatted:
                diagnostics.extend(changed_line_diagnostics(
                    path, (root / path).read_text(encoding="utf-8"), formatted[path],
                ))
            elif path not in parse_errors:
                diagnostics.append(diagnostic(path, "Dart 格式化未完成，详见工作流日志。"))
        if result.returncode and len(formatted) == len(batch):
            diagnostics.append(diagnostic(None, "Dart 格式化命令执行失败，详见工作流日志。"))
    return diagnostics


def write_report(root, destination, base=None):
    diagnostics = []
    try:
        diagnostics = collect_diagnostics(root, selected_files(root, base), base)
    except (ValueError, SyntaxError, OSError, subprocess.CalledProcessError) as error:
        print(f"格式检查失败：{error}", file=sys.stderr)
        diagnostics.append(diagnostic(None, "格式检查未完成，详见工作流日志。"))
    report = {
        "version": 1,
        "pr_number": int(os.environ.get("FORMAT_PR_NUMBER", "0")),
        "head_sha": os.environ.get("FORMAT_HEAD_SHA", ""),
        "run_id": int(os.environ.get("GITHUB_RUN_ID", "0")),
        "run_attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "0")),
        "passed": not diagnostics,
        "total": len(diagnostics),
        "diagnostics": diagnostics[:200],
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, ensure_ascii=False) + "\n", encoding="utf-8")
    def escape(value):
        return str(value).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")

    for index, item in enumerate(diagnostics):
        print("诊断：" + json.dumps(item, ensure_ascii=False))
        if index >= 50:
            continue
        properties = ""
        if item["path"]:
            properties = " file=" + escape(item["path"]).replace(",", "%2C").replace(":", "%3A")
            if item["line"]:
                properties += f",line={item['line']},endLine={item['end_line']}"
        print(f"::error{properties}::{escape(item['message'])}")
    print(f"格式检查{'通过' if report['passed'] else '失败'}；发现 {report['total']} 处问题。")
    return 0 if report["passed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=os.environ.get("FORMAT_BASE_SHA"))
    parser.add_argument("--fix", action="store_true", help="应用 Dart 格式化，默认仅检查")
    parser.add_argument("--report", type=Path, help="仅检查并保存包含文件和行号的 JSON 报告")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    if args.report:
        if args.fix:
            parser.error("--report 不能与 --fix 同时使用")
        return write_report(root, args.report, args.base)
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
