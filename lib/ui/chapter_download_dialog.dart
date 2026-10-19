import 'package:flutter/material.dart';
import '../data/download_queue.dart';
import '../data/library.dart';
import '../domain/models.dart';
import '../sources/chapter_subscription_source.dart';
import 'account.dart';
import 'chapter_subscription_dialog.dart';

Future<void> showChapterDownloadDialog(
  BuildContext context, {
  required Library library,
  required Book book,
  DownloadTask? previousTask,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      DownloadDialog(library: library, book: book, previousTask: previousTask),
);

class DownloadDialog extends StatefulWidget {
  const DownloadDialog({
    super.key,
    required this.library,
    required this.book,
    this.previousTask,
  });
  final Library library;
  final Book book;
  final DownloadTask? previousTask;
  @override
  State<DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<DownloadDialog> {
  final start = TextEditingController(text: '1');
  late final end = TextEditingController(
    text: '${widget.book.chapters.length}',
  );
  bool running = false, cancelled = false, refreshCached = false;
  bool subscriptionOpen = false;
  int done = 0, total = 0, success = 0;
  String status = '选择需要保存到本机的章节范围';
  final failures = <String>[];
  final subscriptionFailures = <String>{};
  DownloadTask? task;
  int taskRevision = -1;
  late final chapterTitles = {
    for (final chapter in widget.book.chapters) chapter.id: chapter.title,
  };
  @override
  void initState() {
    super.initState();
    widget.library.downloadQueue.addListener(_syncTask);
    final previous = widget.previousTask;
    if (previous != null) {
      start.text =
          '${widget.book.chapters.indexWhere((c) => c.id == previous.chapters.first.id) + 1}';
      end.text =
          '${widget.book.chapters.indexWhere((c) => c.id == previous.chapters.last.id) + 1}';
      refreshCached = previous.refreshCached;
      subscriptionFailures.addAll(
        previous.failures.entries
            .where((e) => e.value is SubscriptionRequiredException)
            .map((e) => e.key),
      );
    }
  }

  @override
  void dispose() {
    widget.library.downloadQueue.removeListener(_syncTask);
    start.dispose();
    end.dispose();
    super.dispose();
  }

  void _syncTask() {
    final current = task;
    if (!mounted || current == null || current.revision == taskRevision) return;
    taskRevision = current.revision;
    setState(() {
      running = current.pending;
      cancelled =
          current.state == DownloadTaskState.stopping ||
          current.state == DownloadTaskState.cancelled;
      done = current.done;
      total = current.chapters.length;
      success = current.success;
      failures.clear();
      subscriptionFailures.clear();
      final errors = current.failures;
      for (final entry in errors.entries) {
        final error = entry.value;
        failures.add('${chapterTitles[entry.key]}：$error');
        if (error is SubscriptionRequiredException) {
          subscriptionFailures.add(entry.key);
        }
      }
      status = switch (current.state) {
        DownloadTaskState.queued => '已加入队列，等待前方任务完成',
        DownloadTaskState.running =>
          '${current.chapterTitle.isEmpty ? '正在下载…' : current.chapterTitle} · $done / $total',
        DownloadTaskState.stopping => '正在停止…',
        DownloadTaskState.cancelled =>
          '已停止 · 成功 $success 章，失败 ${failures.length} 章',
        DownloadTaskState.completed || DownloadTaskState.failed =>
          current.error != null
              ? '下载失败：${current.error}'
              : '下载完成 · 成功 $success 章，失败 ${failures.length} 章',
      };
    });
  }

  void _run() {
    if (running || subscriptionOpen) return;
    final from = int.tryParse(start.text), to = int.tryParse(end.text);
    if (from == null ||
        to == null ||
        from < 1 ||
        to < from ||
        to > widget.book.chapters.length) {
      setState(() => status = '请输入有效的起止章序号');
      return;
    }
    setState(() {
      running = true;
      cancelled = false;
      done = 0;
      success = 0;
      total = to - from + 1;
      failures.clear();
      subscriptionFailures.clear();
      status = '正在准备下载…';
    });
    try {
      task = widget.library.downloadQueue.enqueue(
        widget.book,
        widget.book.chapters.sublist(from - 1, to),
        refreshCached: refreshCached,
      );
      taskRevision = -1;
      _syncTask();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        running = false;
        status = '下载失败：$error';
      });
      return;
    }
  }

  Future<void> _subscribe(ChapterSubscriptionSource source) async {
    if (running || subscriptionOpen) return;
    final from = int.tryParse(start.text), to = int.tryParse(end.text);
    if (from == null ||
        to == null ||
        from < 1 ||
        to < from ||
        to > widget.book.chapters.length) {
      setState(() => status = '请输入有效的起止章序号');
      return;
    }
    final range = widget.book.chapters.sublist(from - 1, to);
    final first =
        range.where((c) => subscriptionFailures.contains(c.id)).firstOrNull ??
        range.first;
    setState(() => subscriptionOpen = true);
    try {
      if (!source.canSubscribe) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => AccountSettingsPage(library: widget.library),
          ),
        );
        return;
      }
      final subscribed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ChapterSubscriptionDialog(
          source: source,
          book: widget.book,
          first: first,
        ),
      );
      if (!mounted || subscribed != true) return;
      setState(() {
        subscriptionFailures.clear();
        status = '订阅成功，请点击下载按钮继续保存章节。';
      });
    } finally {
      if (mounted) setState(() => subscriptionOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !subscriptionOpen,
    child: AlertDialog(
      title: const Text('下载章节'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: start,
                      enabled: !running && !subscriptionOpen,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '起始章'),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: TextField(
                      controller: end,
                      enabled: !running && !subscriptionOpen,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '结束章'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(status),
              const SizedBox(height: 8),
              const Text(
                '关闭窗口后继续下载，可在“下载 → 正在下载”查看进度。',
                style: TextStyle(fontSize: 12),
              ),
              if (total > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: LinearProgressIndicator(value: done / total),
                ),
              const SizedBox(height: 12),
              CheckboxListTile(
                key: const ValueKey('refresh-cached-chapters'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('重新获取已缓存章节'),
                value: refreshCached,
                onChanged: running || subscriptionOpen
                    ? null
                    : (value) => setState(() => refreshCached = value ?? false),
              ),
              const Text(
                '默认复用已缓存正文。旧版起点缓存需要重新获取才能使用段评；'
                '获取失败会保留原正文和阅读进度。付费章节需要已有权限。',
                style: TextStyle(fontSize: 12),
              ),
              if (widget.library.sourceFor(widget.book)
                  case ChapterSubscriptionSource()) ...[
                const SizedBox(height: 12),
                const Text(
                  '可先订阅再下载；确认费用后才会订阅，下载不会自动购买章节。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
              for (final f in failures)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(f, style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (running)
          TextButton(
            onPressed: cancelled
                ? null
                : () => widget.library.downloadQueue.cancel(task!),
            child: Text(cancelled ? '正在停止…' : '停止下载'),
          ),
        TextButton(
          onPressed: subscriptionOpen ? null : () => Navigator.pop(context),
          child: Text(running ? '后台下载' : '关闭'),
        ),
        if (widget.library.sourceFor(widget.book)
            case final ChapterSubscriptionSource source)
          OutlinedButton.icon(
            key: const ValueKey('download-subscribe'),
            onPressed: running || subscriptionOpen
                ? null
                : () => _subscribe(source),
            icon: const Icon(Icons.shopping_cart_outlined),
            label: Text(source.canSubscribe ? '订阅后续章节' : '登录后订阅'),
          ),
        FilledButton(
          onPressed: running || subscriptionOpen ? null : _run,
          child: Text(done == 0 ? '开始下载' : '重新下载'),
        ),
      ],
    ),
  );
}
