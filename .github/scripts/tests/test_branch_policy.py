import os
from pathlib import Path
import subprocess
import textwrap
import unittest


class BranchPolicyTests(unittest.TestCase):
    def test_actual_workflow_script_accepts_only_same_repository_dev_and_reports_head_sha(self):
        workflow = Path(__file__).resolve().parents[2] / "workflows/branch-policy.yml"
        script = textwrap.dedent(workflow.read_text(encoding="utf-8").split("script: |\n", 1)[1])
        harness = r"""
const assert = require('node:assert/strict');
const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
const run = new AsyncFunction('github', 'context', 'core', process.argv[1]);
process.env.GITHUB_SERVER_URL = 'https://github.com';
(async () => {
  for (const [branch, repositoryId, base, expected] of [
    ['dev', 1, 'master', 'success'],
    ['feature/read', 1, 'master', 'failure'],
    ['master', 1, 'master', 'failure'],
    ['main', 1, 'master', 'failure'],
    ['dev', 2, 'master', 'failure'],
    ['dev', null, 'master', 'failure'],
    ['dev', 1, 'dev', 'failure'],
    ['dev', 1, 'main', 'failure'],
    ['dev"; process.exit(0)', 1, 'master', 'failure'],
  ]) {
    let failed = false;
    const calls = [];
    const context = {
      repo: {owner: 'owner', repo: 'unr'},
      runId: 123,
      payload: {
        repository: {id: 1},
        pull_request: {
          base: {ref: base},
          head: {ref: branch, sha: 'PR-HEAD-SHA', repo: repositoryId == null ? null : {id: repositoryId}},
        },
      },
    };
    await run(
      {rest: {repos: {createCommitStatus: async status => calls.push(status)}}},
      context,
      {setFailed: () => failed = true},
    );
    assert.equal(calls.length, 1);
    assert.equal(calls[0].state, expected);
    assert.equal(calls[0].sha, 'PR-HEAD-SHA');
    assert.equal(calls[0].context, 'dev-to-master');
    assert.equal(calls[0].target_url, 'https://github.com/owner/unr/actions/runs/123');
    assert.equal(failed, expected === 'failure');
  }
})().catch(error => { console.error(error); process.exit(1); });
"""
        result = subprocess.run(
            [os.environ.get("UNR_TEST_NODE", "node"), "-e", harness, script],
            capture_output=True, text=True, encoding="utf-8", timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
