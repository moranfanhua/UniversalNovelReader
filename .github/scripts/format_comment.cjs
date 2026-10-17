const fs = require('node:fs');

const marker = '<!-- unr-format-report -->';
const metadata = /<!-- unr-format-run:(\d+):(\d+) -->/;
const positiveInteger = value => Number.isSafeInteger(value) && value > 0;
const escape = value => String(value).replace(/[&<>"'`@|\[\]()\\\r\n]/g, char => `&#${char.charCodeAt(0)};`);
const encodePath = value => encodeURIComponent(value).replace(/[!'()*]/g, char => `%${char.charCodeAt(0).toString(16).toUpperCase()}`);

function readReport(reportPath) {
  if (fs.statSync(reportPath).size > 1024 * 1024) throw new Error('格式报告过大');
  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  if (report.version !== 1 || !positiveInteger(report.pr_number)
      || !/^[0-9a-f]{40}$/.test(report.head_sha)
      || !positiveInteger(report.run_id) || !positiveInteger(report.run_attempt)
      || typeof report.passed !== 'boolean'
      || !Number.isSafeInteger(report.total) || report.total < 0
      || !Array.isArray(report.diagnostics) || report.diagnostics.length > 200
      || report.total < report.diagnostics.length
      || report.passed !== (report.total === 0)
      || (!report.passed && report.diagnostics.length === 0)) {
    throw new Error('格式报告结构无效');
  }
  for (const item of report.diagnostics) {
    if (!item || typeof item.message !== 'string' || item.message.length > 4000
        || (item.path !== null && (typeof item.path !== 'string' || !item.path
          || item.path.length > 1000 || /[\\:\x00-\x1f\x7f]/.test(item.path)
          || item.path.split('/').some(part => !part || part === '.' || part === '..')))
        || (item.line !== null && (!positiveInteger(item.line) || item.line > 10000000))
        || (item.line === null ? item.end_line !== null
          : !positiveInteger(item.end_line) || item.end_line < item.line || item.end_line > 10000000)
        || (item.path === null && item.line !== null)) {
      throw new Error('格式报告诊断无效');
    }
  }
  return report;
}

function commentBody(report, run, pr, serverUrl) {
  const runUrl = `${serverUrl}/${pr.base.repo.full_name}/actions/runs/${run.id}/attempts/${run.run_attempt}`;
  const commitUrl = `${serverUrl}/${pr.head.repo.full_name}/commit/${report.head_sha}`;
  const lines = [
    marker,
    `<!-- unr-format-run:${run.id}:${run.run_attempt} -->`,
    report.passed ? '### 格式检查已通过' : '### 格式检查未通过',
    '',
    `提交：[${report.head_sha.slice(0, 7)}](${commitUrl}) · [查看检查日志](${runUrl})`,
    '',
  ];
  if (report.passed) {
    lines.push('之前报告的格式问题已修复。');
  } else {
    lines.push('| 文件与行号 | 问题 |', '| --- | --- |');
    let displayed = 0;
    let length = lines.join('\n').length;
    for (const item of report.diagnostics.slice(0, 50)) {
      let location = '检查环境';
      if (item.path !== null) {
        const path = item.path.split('/').map(encodePath).join('/');
        let url = `${serverUrl}/${pr.head.repo.full_name}/blob/${report.head_sha}/${path}`;
        let label = item.path;
        if (item.line !== null) {
          url += `#L${item.line}-L${item.end_line}`;
          label += `:${item.line}${item.end_line > item.line ? `–${item.end_line}` : ''}`;
        }
        location = `[<code>${escape(label)}</code>](${url})`;
      }
      const row = `| ${location} | <code>${escape(item.message.slice(0, 1000))}</code> |`;
      if (length + row.length > 50000) break;
      lines.push(row);
      length += row.length + 1;
      displayed++;
    }
    lines.push('', '请运行 `dart format <问题文件>` 修复 Dart 格式；JSON、Python 或空白问题请按上表修正。');
    if (report.total > displayed) lines.push('', `共 ${report.total} 处问题，本评论展示前 ${displayed} 处，其余请查看检查日志。`);
  }
  return lines.join('\n');
}

async function publishFormatComment({github, context, core, reportPath}) {
  const run = context.payload.workflow_run;
  if (run.event !== 'pull_request' || run.path !== '.github/workflows/format.yml'
      || run.repository.id !== context.payload.repository.id) {
    throw new Error('报告来源不是本仓库的 PR 格式检查');
  }
  const report = readReport(reportPath);
  if (report.head_sha !== run.head_sha || report.run_id !== run.id || report.run_attempt !== run.run_attempt) {
    core.notice('报告与本次工作流提交或重跑次数不一致，跳过评论。');
    return;
  }
  const {data: pr} = await github.rest.pulls.get({...context.repo, pull_number: report.pr_number});
  // fork 的 workflow_run.pull_requests 可能为空，因此通过实时 PR 和服务器元数据核对归属。
  if (pr.state !== 'open' || !['dev', 'master'].includes(pr.base.ref)
      || pr.base.repo.id !== context.payload.repository.id
      || pr.head.sha !== report.head_sha || pr.head.repo?.id !== run.head_repository.id
      || pr.head.ref !== run.head_branch
      || (run.pull_requests.length > 0 && !run.pull_requests.some(item => item.number === pr.number))) {
    core.notice('PR 已关闭、已更新或不属于本次检查，跳过评论。');
    return;
  }
  const comments = await github.paginate(github.rest.issues.listComments, {
    ...context.repo, issue_number: pr.number, per_page: 100,
  });
  const previous = comments.find(item => item.user?.login === 'github-actions[bot]'
    && item.user.type === 'Bot' && item.body?.startsWith(marker));
  const lastRun = previous?.body.match(metadata);
  if (lastRun && (Number(lastRun[1]) > run.id
      || (Number(lastRun[1]) === run.id && Number(lastRun[2]) > run.run_attempt))) {
    core.notice('已有更新的格式检查反馈，跳过旧结果。');
    return;
  }
  if (report.passed && !previous) return;
  // 发布前再次确认 head，避免读取报告期间的新推送留下过期评论。
  const {data: latest} = await github.rest.pulls.get({...context.repo, pull_number: pr.number});
  if (latest.state !== 'open' || latest.head.sha !== report.head_sha) {
    core.notice('PR 在发布前已更新，跳过评论。');
    return;
  }
  const body = commentBody(report, run, pr, process.env.GITHUB_SERVER_URL || 'https://github.com');
  if (previous) {
    await github.rest.issues.updateComment({...context.repo, comment_id: previous.id, body});
  } else {
    await github.rest.issues.createComment({...context.repo, issue_number: pr.number, body});
  }
}

module.exports = {publishFormatComment};
