import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class FormatCommentTests(unittest.TestCase):
    def setUp(self):
        self.report = {
            "version": 1, "pr_number": 12, "head_sha": "a" * 40, "run_id": 34, "run_attempt": 1,
            "passed": False, "total": 1,
            "diagnostics": [{"path": "lib/中文 name.dart", "message": "请格式化", "line": 3, "end_line": 5}],
        }
        self.pr = {
            "number": 12, "state": "open",
            "base": {"ref": "dev", "repo": {"id": 1, "full_name": "owner/unr"}},
            "head": {"sha": "a" * 40, "ref": "feature/reader", "repo": {"id": 2, "full_name": "fork/unr"}},
        }
        self.run = {
            "id": 34, "run_attempt": 1, "event": "pull_request", "path": ".github/workflows/format.yml",
            "repository": {"id": 1}, "head_repository": {"id": 2}, "head_sha": "a" * 40,
            "head_branch": "feature/reader", "pull_requests": [],
        }

    def publish(self, comments=(), latest=None):
        module = Path(__file__).resolve().parents[1] / "format_comment.cjs"
        harness = r"""
const fs = require('node:fs');
const assert = require('node:assert/strict');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const {publishFormatComment} = require(process.argv[1]);
const output = {created: [], updated: [], notices: [], reads: 0};
const listComments = () => {};
const github = {
  rest: {
    pulls: {get: async params => {
      assert.equal(params.owner, 'owner');
      assert.equal(params.repo, 'unr');
      assert.equal(params.pull_number, 12);
      output.reads++;
      return {data: output.reads > 1 && input.latest ? input.latest : input.pr};
    }},
    issues: {
      listComments,
      createComment: async value => output.created.push(value),
      updateComment: async value => output.updated.push(value),
    },
  },
  paginate: async (method, params) => {
    assert.equal(method, listComments);
    assert.equal(params.issue_number, 12);
    assert.equal(params.per_page, 100);
    return input.comments;
  },
};
process.env.GITHUB_SERVER_URL = 'https://github.com';
publishFormatComment({
  github,
  context: {repo: {owner: 'owner', repo: 'unr'}, payload: {repository: {id: 1}, workflow_run: input.run}},
  core: {notice: value => output.notices.push(value)},
  reportPath: process.argv[2],
}).catch(error => {output.error = error.message;})
  .then(() => process.stdout.write(JSON.stringify(output)));
"""
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "report.json"
            report.write_text(json.dumps(self.report), encoding="utf-8")
            result = subprocess.run(
                [os.environ.get("UNR_TEST_NODE", "node"), "-e", harness, str(module), str(report)],
                input=json.dumps({"pr": self.pr, "run": self.run, "comments": comments, "latest": latest}),
                capture_output=True, text=True, encoding="utf-8", timeout=30,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def previous(self, run=33, attempt=1):
        return [{
            "id": 56, "user": {"login": "github-actions[bot]", "type": "Bot"},
            "body": f"<!-- unr-format-report -->\n<!-- unr-format-run:{run}:{attempt} -->\n旧结果",
        }]

    def assert_no_write(self, output):
        self.assertEqual(output["created"], [])
        self.assertEqual(output["updated"], [])

    def test_failed_fork_pr_gets_comment_with_head_file_line_links(self):
        output = self.publish()
        self.assertNotIn("error", output)
        comment, = output["created"]
        self.assertEqual(comment["issue_number"], 12)
        self.assertIn("%E4%B8%AD%E6%96%87%20name.dart#L3-L5", comment["body"])
        self.assertIn("/fork/unr/blob/" + "a" * 40, comment["body"])
        self.assertIn("/actions/runs/34/attempts/1", comment["body"])

    def test_failure_rerun_updates_its_bot_comment_and_ignores_human_marker(self):
        output = self.publish(self.previous())
        self.assertEqual(output["created"], [])
        self.assertEqual(output["updated"][0]["comment_id"], 56)
        human = self.previous()
        human[0]["user"] = {"login": "contributor", "type": "User"}
        self.assertEqual(len(self.publish(human)["created"]), 1)

    def test_success_only_updates_existing_failure_feedback(self):
        self.report.update(passed=True, total=0, diagnostics=[])
        self.assert_no_write(self.publish())
        output = self.publish(self.previous())
        self.assertIn("格式检查已通过", output["updated"][0]["body"])

    def test_stale_closed_or_unrelated_pr_is_never_commented(self):
        for scenario in ("stale", "closed", "repository", "branch", "association"):
            with self.subTest(scenario=scenario):
                self.setUp()
                if scenario == "stale": self.pr["head"]["sha"] = "b" * 40
                if scenario == "closed": self.pr["state"] = "closed"
                if scenario == "repository": self.pr["head"]["repo"]["id"] = 3
                if scenario == "branch": self.run["head_branch"] = "other"
                if scenario == "association": self.run["pull_requests"] = [{"number": 99}]
                output = self.publish()
                self.assertNotIn("error", output)
                self.assert_no_write(output)
                self.assertTrue(output["notices"])

    def test_report_identity_and_newer_feedback_prevent_old_results_overwriting(self):
        for scenario in ("sha", "attempt", "run", "newer_comment", "newer_attempt", "updated_during_read"):
            with self.subTest(scenario=scenario):
                self.setUp()
                comments = []
                latest = None
                if scenario == "sha": self.report["head_sha"] = "b" * 40
                if scenario == "attempt": self.report["run_attempt"] = 2
                if scenario == "run": self.report["run_id"] = 33
                if scenario == "newer_comment": comments = self.previous(run=35)
                if scenario == "newer_attempt": comments = self.previous(run=34, attempt=2)
                if scenario == "updated_during_read":
                    latest = copy.deepcopy(self.pr)
                    latest["head"]["sha"] = "b" * 40
                output = self.publish(comments, latest)
                self.assertNotIn("error", output)
                self.assert_no_write(output)

    def test_untrusted_paths_schema_and_wrong_source_are_rejected(self):
        for scenario in ("traversal", "absolute", "line", "status", "source"):
            with self.subTest(scenario=scenario):
                self.setUp()
                if scenario == "traversal": self.report["diagnostics"][0]["path"] = "../secret"
                if scenario == "absolute": self.report["diagnostics"][0]["path"] = "/etc/passwd"
                if scenario == "line": self.report["diagnostics"][0]["line"] = -1
                if scenario == "status": self.report["passed"] = True
                if scenario == "source": self.run["path"] = ".github/workflows/unrelated.yml"
                output = self.publish()
                self.assertIn("error", output)
                self.assert_no_write(output)

    def test_comment_escapes_mentions_markdown_and_limits_large_reports(self):
        self.report["diagnostics"][0]["path"] = "lib/name(with)quotes'.dart"
        self.report["diagnostics"][0]["message"] = '@someone | </code><script>bad</script> [x](https://evil.invalid)'
        output = self.publish()
        body = output["created"][0]["body"]
        self.assertNotIn("@someone", body)
        self.assertNotIn("<script>", body)
        self.assertNotIn("[x](", body)
        self.assertIn("name%28with%29quotes%27.dart#L3-L5", body)
        self.report["diagnostics"] *= 200
        self.report["total"] = 400
        body = self.publish()["created"][0]["body"]
        self.assertIn("本评论展示前 50 处", body)
        self.assertLess(len(body), 65536)
