import 'dart:async';
import 'package:flutter/material.dart';
import '../data/library.dart';
import '../domain/models.dart';

class BatchDownloadDialog extends StatefulWidget {
  const BatchDownloadDialog({
    super.key,
    required this.library,
    required this.books,
  });
  final Library library;
  final List<Book> books;
  @override
  State<BatchDownloadDialog> createState() => _BatchDownloadDialogState();
}

class _BatchDownloadDialogState extends State<BatchDownloadDialog> {
  bool running = true, cancelled = false;
  int done = 0, success = 0, failed = 0;
  late final total = widget.books.fold(
    0,
    (sum, book) => sum + book.chapters.length,
  );
  String status = '正在准备下载…';
  final failures = <String>[];

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    cancelled = true;
    super.dispose();
  }

  Future<void> _run() async {
    for (var i = 0; i < widget.books.length; i++) {
      if (cancelled || !mounted) break;
      final book = widget.books[i];
      var processed = 0, bookFailed = 0;
      Object? firstError;
      setState(
        () => status = '第 ${i + 1} / ${widget.books.length} 本 · ${book.title}',
      );
      try {
        await widget.library.downloadChapters(
          book,
          book.chapters,
          isCancelled: () => cancelled || !mounted,
          onProgress: (chapter, error) {
            if (!mounted) return;
            setState(() {
              processed++;
              done++;
              if (error == null) {
                success++;
              } else {
                failed++;
                bookFailed++;
                firstError ??= error;
              }
            });
          },
        );
      } catch (error) {
        if (!mounted) return;
        final remaining = book.chapters.length - processed;
        setState(() {
          done += remaining;
          failed += remaining;
          bookFailed += remaining;
          firstError ??= error;
        });
      }
      if (!mounted) return;
      if (firstError != null) {
        setState(
          () => failures.add(
            '${book.title}（${widget.library.sourceName(book)}）：$bookFailed 章失败，$firstError',
          ),
        );
      }
    }
    if (mounted) setState(() => running = false);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !running,
    child: AlertDialog(
      title: const Text('批量下载'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                running
                    ? status
                    : '${cancelled ? '已停止' : '下载完成'} · 成功 $success 章，失败 $failed 章',
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: total == 0 ? 0 : done / total),
              const SizedBox(height: 8),
              Text('已处理 $done / $total 章'),
              const SizedBox(height: 12),
              const Text('按所选书籍的当前目录下载全部章节，复用已有缓存。付费章节需要已有权限，不会自动购买。'),
              for (final failure in failures) ...[
                const SizedBox(height: 8),
                Text(
                  failure,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (running)
          TextButton(
            onPressed: cancelled
                ? null
                : () => setState(() => cancelled = true),
            child: Text(cancelled ? '正在停止…' : '停止下载'),
          )
        else
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
      ],
    ),
  );
}
