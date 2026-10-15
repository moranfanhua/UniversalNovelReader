import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/app_log.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key, this.log, this.export});
  final AppLog? log;
  final Future<bool> Function(Uint8List bytes)? export;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  AppLog get log => widget.log ?? AppLog.instance;
  LogSnapshot? snapshot;
  bool busy = false, confirmingClear = false;
  String? error;

  String get preview {
    final text = snapshot?.text ?? '正在读取日志…';
    const limit = 64 * 1024;
    if (text.length <= limit) return text;
    final start = text.indexOf('\n', text.length - limit);
    return '仅显示最近的日志，导出包含全部保留记录。\n\n${text.substring(start < 0 ? text.length - limit : start + 1)}';
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (failure, stack) {
      log.record(
        LogLevel.error,
        'log.operation_failed',
        error: failure,
        stackTrace: stack,
      );
      if (mounted) setState(() => error = '日志操作失败，请重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _refresh() => _run(() async {
    final next = await log.snapshot();
    if (mounted) setState(() => snapshot = next);
  });

  Future<void> _export() => _run(() async {
    final next = await log.snapshot();
    if (!mounted) return;
    setState(() => snapshot = next);
    final bytes = Uint8List.fromList(utf8.encode(next.text));
    final exporter = widget.export;
    final saved = exporter != null
        ? await exporter(bytes)
        : await FilePicker.saveFile(
                fileName:
                    'UNR-日志-${DateTime.now().toIso8601String().replaceAll(':', '-')}.txt',
                bytes: bytes,
                mimeType: 'text/plain',
                dialogTitle: '导出日志',
              ) !=
              null;
    if (mounted && saved) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('日志已导出')));
    }
  });

  Future<void> _clear() async {
    if (busy) return;
    // Reserve the action while the dialog is open to avoid overlapping requests.
    setState(() {
      busy = true;
      confirmingClear = true;
    });
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空日志？'),
        content: const Text('删除本机诊断日志，之后发生的事件会继续记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() {
      busy = false;
      confirmingClear = false;
    });
    if (confirmed != true) return;
    await _run(() async {
      await log.clear();
      final next = await log.snapshot();
      if (mounted) setState(() => snapshot = next);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('日志')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('日志仅保存在本机，自动轮换，最多约 1.5 MB。导出后可用于反馈问题。'),
                    const SizedBox(height: 8),
                    const Text('记录事件、状态码、耗时和代码位置，不记录账号、密码、会话、请求内容或小说正文。'),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: busy ? null : _refresh,
                          icon: const Icon(Icons.refresh),
                          label: const Text('刷新'),
                        ),
                        FilledButton.icon(
                          onPressed: busy || snapshot == null ? null : _export,
                          icon: const Icon(Icons.file_download_outlined),
                          label: const Text('导出日志'),
                        ),
                        TextButton.icon(
                          onPressed: busy ? null : _clear,
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('清空日志'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (busy && !confirmingClear) const LinearProgressIndicator(),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (snapshot?.storageUnavailable == true)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('日志存储不可用，仅显示本次运行的最近记录。可导出后重试。'),
                ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  preview,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
