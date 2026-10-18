import json
import os
from pathlib import Path
import subprocess
import textwrap
import unittest


class PrCheckerTests(unittest.TestCase):
    def check(self, title, commits=(), base="dev", api_error=False, comments=(), comment_error=False, latest=None):
        workflow = Path(__file__).resolve().parents[2] / "workflows/pr-checker.yml"
        script = textwrap.dedent(workflow.read_text(encoding="utf-8").split("script: |\n", 1)[1])
        harness = r"""
const fs = require('node:fs');
const assert = require('node:assert/strict');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const output = {statuses: [], failures: [], pagination: 0, created: [], updated: [], warnings: [], notices: []};
const summary = {addHeading() {return this;}, addList() {return this;}, async write() {}};
const listCommits = () => {};
const listComments = () => {};
const github = {
  rest: {
    pulls: {listCommits, get: async params => {
      assert.equal(params.pull_number, 12);
      return {data: {...context.payload.pull_request, state: 'open', ...input.latest}};
    }},
    repos: {createCommitStatus: async value => output.statuses.push(value)},
    issues: {
      listComments,
      createComment: async value => {
        if (input.comment_error) throw new Error('Comment API unavailable');
        output.created.push(value);
      },
      updateComment: async value => {
        if (input.comment_error) throw new Error('Comment API unavailable');
        output.updated.push(value);
      },
    },
  },
  async paginate(method, params) {
    assert.equal(params.per_page, 100);
    if (method === listComments) {
      assert.equal(params.issue_number, 12);
      return input.comments;
    }
    assert.equal(method, listCommits);
    assert.equal(params.pull_number, 12);
    output.pagination++;
    if (input.api_error) throw new Error('API unavailable');
    return input.commits.map((item, index) => ({
      sha: String(index).padStart(7, '0') + 'a'.repeat(33),
      commit: {message: item[0]}, parents: Array(item[1]).fill({sha: 'parent'}),
    }));
  },
};
const context = {
  repo: {owner: 'owner', repo: 'unr'}, runId: 34,
  payload: {pull_request: {number: 12, title: input.title, base: {ref: input.base}, head: {sha: 'pr-head'}}},
};
const core = {
  summary, error() {}, setFailed: value => output.failures.push(value),
  warning: value => output.warnings.push(value), notice: value => output.notices.push(value),
};
process.env.GITHUB_SERVER_URL = 'https://github.com';
process.env.GITHUB_RUN_ATTEMPT = '1';
const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
new AsyncFunction('github', 'context', 'core', process.argv[1])(github, context, core)
  .then(() => process.stdout.write(JSON.stringify(output)))
  .catch(error => {console.error(error); process.exitCode = 1;});
"""
        result = subprocess.run(
            [os.environ.get("UNR_TEST_NODE", "node"), "-e", harness, script],
            input=json.dumps({
                "title": title, "commits": commits, "base": base, "api_error": api_error,
                "comments": comments, "comment_error": comment_error, "latest": latest,
            }),
            capture_output=True, text=True, encoding="utf-8", timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        output = json.loads(result.stdout)
        status, = output["statuses"]
        self.assertEqual(status["sha"], "pr-head")
        self.assertEqual(status["context"], "pr-conventions")
        return status["state"], output

    def test_chinese_conventions_and_dependabot_prefix_are_accepted(self):
        for title in ("feat(reader): 支持 EPUB 导入", "fix!: 修复进度恢复", "ci(deps): 更新 Bump actions/checkout"):
            with self.subTest(title=title):
                state, _ = self.check(title, [(title, 1)])
                self.assertEqual(state, "success")

    def test_invalid_titles_and_missing_spacing_are_rejected(self):
        for title in ("更新功能", "feat: add feature", "fix(reader): 修复EPUB导入", "fix: 修复\n$(exit 0)"):
            with self.subTest(title=title):
                state, output = self.check(title)
                self.assertEqual(state, "failure")
                self.assertTrue(output["failures"])

    def test_invalid_commit_after_first_page_is_rejected(self):
        commits = [("fix: 修复阅读", 1)] * 100 + [("invalid commit", 1)]
        state, output = self.check("fix: 修复阅读", commits)
        self.assertEqual(state, "failure")
        self.assertEqual(output["pagination"], 1)
        self.assertIn("invalid commit", output["failures"][0])

    def test_merge_and_release_sync_commits_remain_allowed(self):
        state, _ = self.check("ci: 同步稳定分支", [("Merge branch master", 2), ("Release v0.3.0 (#7)", 1)])
        self.assertEqual(state, "success")

    def test_master_uses_release_title_without_rechecking_history(self):
        state, output = self.check("Release v0.3.1-rc.1", [("historical title", 1)], base="master")
        self.assertEqual(state, "success")
        self.assertEqual(output["pagination"], 0)
        state, _ = self.check("feat: 功能变更", base="master")
        self.assertEqual(state, "failure")

    def test_api_failure_reports_failure_on_pr_head(self):
        state, output = self.check("fix: 修复阅读", api_error=True)
        self.assertEqual(state, "failure")
        self.assertIn("无法读取完整", output["failures"][0])

    def previous(self, run=33, attempt=1):
        return [{
            "id": 56, "user": {"login": "github-actions[bot]", "type": "Bot"},
            "body": f"<!-- unr-pr-conventions -->\n<!-- unr-pr-conventions-run:{run}:{attempt} -->\n旧结果",
        }]

    def test_failure_comment_identifies_invalid_title_and_commit(self):
        state, output = self.check("更新功能", [("invalid commit", 1)])
        self.assertEqual(state, "failure")
        comment, = output["created"]
        self.assertEqual(comment["issue_number"], 12)
        self.assertIn("PR 标题须使用中文约定式格式", comment["body"])
        self.assertIn("0000000 的提交标题", comment["body"])
        self.assertIn("invalid commit", comment["body"])
        self.assertIn("/actions/runs/34/attempts/1", comment["body"])
        self.assertFalse(output["warnings"])

    def test_rerun_updates_bot_comment_and_success_resolves_existing_failure(self):
        for title, expected in (("更新功能", "未通过"), ("fix: 修复阅读", "已通过")):
            with self.subTest(title=title):
                _, output = self.check(title, comments=self.previous())
                self.assertEqual(output["created"], [])
                self.assertEqual(output["updated"][0]["comment_id"], 56)
                self.assertIn(expected, output["updated"][0]["body"])
                self.assertFalse(output["warnings"])
        _, output = self.check("fix: 修复阅读")
        self.assertEqual(output["created"], [])
        self.assertEqual(output["updated"], [])

    def test_feedback_ignores_human_and_formatting_comments(self):
        human = self.previous()
        human[0]["user"] = {"login": "contributor", "type": "User"}
        formatting = self.previous()
        formatting[0]["body"] = "<!-- unr-format-report -->\n格式检查未通过"
        _, output = self.check("更新功能", comments=human + formatting)
        self.assertEqual(len(output["created"]), 1)
        self.assertEqual(output["updated"], [])

    def test_old_results_do_not_comment_after_title_or_head_changes_or_closure(self):
        for latest in (
            {"title": "fix: 修复标题"}, {"head": {"sha": "new-head"}},
            {"base": {"ref": "master"}}, {"state": "closed"},
        ):
            with self.subTest(latest=latest):
                _, output = self.check("更新功能", latest=latest)
                self.assertEqual(output["created"], [])
                self.assertEqual(output["updated"], [])
                self.assertTrue(output["notices"])
        for comments in (self.previous(run=35), self.previous(run=34, attempt=2)):
            with self.subTest(comments=comments):
                _, output = self.check("更新功能", comments=comments)
                self.assertEqual(output["created"], [])
                self.assertEqual(output["updated"], [])

    def test_comment_failure_does_not_hide_check_failure_or_fail_a_passing_check(self):
        for title, expected in (("更新功能", "failure"), ("fix: 修复阅读", "success")):
            with self.subTest(title=title):
                state, output = self.check(title, comments=self.previous(), comment_error=True)
                self.assertEqual(state, expected)
                self.assertEqual(bool(output["failures"]), expected == "failure")
                self.assertTrue(output["warnings"])

    def test_comments_escape_untrusted_text_and_bound_large_error_lists(self):
        title = '标题 @someone </code><script>bad</script> [link](https://evil.invalid)'
        _, output = self.check(title, [(title, 1)])
        body = output["created"][0]["body"]
        self.assertNotIn("@someone", body)
        self.assertNotIn("<script>", body)
        self.assertNotIn("[link](", body)
        _, output = self.check("fix: 修复阅读", [("invalid commit", 1)] * 101)
        self.assertIn("评论展示前 50 处", output["created"][0]["body"])
        self.assertLess(len(output["created"][0]["body"]), 65536)


if __name__ == "__main__":
    unittest.main()
