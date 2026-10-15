import json
import os
from pathlib import Path
import subprocess
import textwrap
import unittest


class PrCheckerTests(unittest.TestCase):
    def check(self, title, commits=(), base="dev", api_error=False):
        workflow = Path(__file__).resolve().parents[2] / "workflows/pr-checker.yml"
        script = textwrap.dedent(workflow.read_text(encoding="utf-8").split("script: |\n", 1)[1])
        harness = r"""
const fs = require('node:fs');
const assert = require('node:assert/strict');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const output = {statuses: [], failures: [], pagination: 0};
const summary = {addHeading() {return this;}, addList() {return this;}, async write() {}};
const listCommits = () => {};
const github = {
  rest: {pulls: {listCommits}, repos: {createCommitStatus: async value => output.statuses.push(value)}},
  async paginate(method, params) {
    assert.equal(method, listCommits);
    assert.equal(params.pull_number, 12);
    assert.equal(params.per_page, 100);
    output.pagination++;
    if (input.api_error) throw new Error('API unavailable');
    return input.commits.map((item, index) => ({
      sha: `commit-${index}`, commit: {message: item[0]}, parents: Array(item[1]).fill({sha: 'parent'}),
    }));
  },
};
const context = {
  repo: {owner: 'owner', repo: 'unr'}, runId: 34,
  payload: {pull_request: {number: 12, title: input.title, base: {ref: input.base}, head: {sha: 'pr-head'}}},
};
const core = {summary, error() {}, setFailed: value => output.failures.push(value)};
process.env.GITHUB_SERVER_URL = 'https://github.com';
const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
new AsyncFunction('github', 'context', 'core', process.argv[1])(github, context, core)
  .then(() => process.stdout.write(JSON.stringify(output)))
  .catch(error => {console.error(error); process.exitCode = 1;});
"""
        result = subprocess.run(
            [os.environ.get("UNR_TEST_NODE", "node"), "-e", harness, script],
            input=json.dumps({"title": title, "commits": commits, "base": base, "api_error": api_error}),
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


if __name__ == "__main__":
    unittest.main()
