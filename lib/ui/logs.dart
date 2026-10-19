import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_log.dart';
import 'log_entry.dart';
import 'top_dropdown_button.dart';

enum _LogAction { refresh, clear, about }

enum _LogView { all, authentication, businessErrors }

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
  List<LogEntry> entries = [];
  int unreadable = 0;
  bool busy = false, loading = false, pendingRefresh = false;
  Timer? refreshTimer;
  String? error, module;
  _LogView view = _LogView.all;
  final levels = LogLevel.values.toSet();

  @override
  void initState() {
    super.initState();
    log.changes.addListener(_logsChanged);
    _refresh();
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    log.changes.removeListener(_logsChanged);
    super.dispose();
  }

  void _logsChanged() {
    pendingRefresh = true;
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    if (!mounted || busy || refreshTimer != null || !pendingRefresh) return;
    refreshTimer = Timer(const Duration(milliseconds: 200), () {
      refreshTimer = null;
      if (!mounted || busy) return;
      _run(_load, automatic: true);
    });
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool automatic = false,
  }) async {
    if (busy) return;
    setState(() {
      busy = true;
      loading = !automatic;
      if (!automatic) error = null;
    });
    try {
      await action();
    } catch (failure, stack) {
      // A failed automatic refresh must not produce an endless logging loop.
      if (!automatic) {
        log.record(
          LogLevel.error,
          'log.operation_failed',
          error: failure,
          stackTrace: stack,
        );
      }
      if (mounted) setState(() => error = '日志操作失败，请重试。');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          loading = false;
        });
        _scheduleRefresh();
      }
    }
  }

  Future<void> _load() async {
    refreshTimer?.cancel();
    refreshTimer = null;
    pendingRefresh = false;
    final next = await log.snapshot();
    if (!mounted) return;
    final parsed = parseLogEntries(next.text);
    setState(() {
      snapshot = next;
      entries = parsed.entries;
      unreadable = parsed.unreadable;
      if (module != null && !entries.any((entry) => entry.module == module)) {
        module = null;
      }
    });
  }

  Future<void> _refresh() => _run(_load);

  Future<void> _copyAll() => _run(() async {
    await _load();
    if (!mounted) return;
    await Clipboard.setData(ClipboardData(text: snapshot!.text));
    if (mounted) _message('已复制全部日志');
  });

  Future<void> _copyEntry(LogEntry entry) => _run(() async {
    await Clipboard.setData(ClipboardData(text: entry.raw));
    if (mounted) _message('已复制这条日志');
  });

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _export() => _run(() async {
    await _load();
    if (!mounted) return;
    final bytes = Uint8List.fromList(utf8.encode(snapshot!.text));
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
    if (mounted && saved) _message('日志已导出');
  });

  Future<void> _clear() async {
    if (busy) return;
    setState(() => busy = true);
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
    setState(() => busy = false);
    if (confirmed != true) {
      _scheduleRefresh();
      return;
    }
    await _run(() async {
      await log.clear();
      await _load();
    });
  }

  void _about() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('日志说明'),
      content: const SingleChildScrollView(
        child: Text(
          '日志仅保存在本机，自动轮换，最多约 1.5 MB。\n\n'
          '记录事件、状态码、耗时、代码位置及脱敏后的服务端说明；不记录完整请求、响应或异常原文。\n\n'
          '新记录显示在最上方。长按可复制单条日志；复制全部和导出始终包含全部保留记录。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  void _action(_LogAction action) {
    switch (action) {
      case _LogAction.refresh:
        _refresh();
      case _LogAction.clear:
        _clear();
      case _LogAction.about:
        _about();
    }
  }

  List<LogEntry> get filtered => entries.reversed
      .where((entry) {
        if (!levels.contains(entry.level)) return false;
        if (module != null && entry.module != module) return false;
        return switch (view) {
          _LogView.all => true,
          _LogView.authentication => entry.authentication,
          _LogView.businessErrors =>
            !entry.authentication && entry.level != LogLevel.info,
        };
      })
      .toList(growable: false);

  Widget _filters(BuildContext context, int count) {
    final counts = <String, int>{};
    for (final entry in entries) {
      counts.update(entry.module, (value) => value + 1, ifAbsent: () => 1);
    }
    final modules = counts.entries.toList()
      ..sort((a, b) {
        final comparison = b.value.compareTo(a.value);
        return comparison == 0 ? a.key.compareTo(b.key) : comparison;
      });
    final levelFilters = Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final level in LogLevel.values)
          FilterChip(
            key: ValueKey('log-level-${level.name}'),
            label: Text(logLevelName(level)),
            selected: levels.contains(level),
            onSelected: (selected) => setState(() {
              if (selected) {
                levels.add(level);
              } else {
                levels.remove(level);
              }
            }),
          ),
      ],
    );
    final moduleFilter = TopDropdownButton<String>(
      key: const ValueKey('log-module-filter'),
      value: module ?? '',
      menuMaxHeight: 320,
      items: [
        DropdownMenuItem(
          value: '',
          child: Text(
            '全部模块（${entries.length}）',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (final entry in modules)
          DropdownMenuItem(
            value: entry.key,
            child: Text(
              '${logModuleName(entry.key)}（${entry.value}）',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (value) => setState(() => module = value == '' ? null : value),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final item in const {
                _LogView.all: '全部',
                _LogView.authentication: '认证日志',
                _LogView.businessErrors: '业务错误',
              }.entries)
                ChoiceChip(
                  label: Text(item.value),
                  selected: view == item.key,
                  onSelected: (_) => setState(() {
                    view = item.key;
                    module = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth >= 600
                ? Row(
                    children: [
                      Expanded(child: levelFilters),
                      const SizedBox(width: 16),
                      SizedBox(width: 260, child: moduleFilter),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      levelFilters,
                      const SizedBox(height: 4),
                      moduleFilter,
                    ],
                  ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  '显示 $count / ${entries.length} 条',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(
                onPressed:
                    view == _LogView.all &&
                        module == null &&
                        levels.length == LogLevel.values.length
                    ? null
                    : () => setState(() {
                        view = _LogView.all;
                        module = null;
                        levels.addAll(LogLevel.values);
                      }),
                child: const Text('重置筛选'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = filtered;
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (wide)
            IconButton(
              tooltip: '刷新',
              onPressed: busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
          IconButton(
            tooltip: '复制全部',
            onPressed: busy || snapshot == null ? null : _copyAll,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: '导出日志',
            onPressed: busy || snapshot == null ? null : _export,
            icon: const Icon(Icons.save_alt),
          ),
          if (wide)
            IconButton(
              tooltip: '清空日志',
              onPressed: busy ? null : _clear,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
          PopupMenuButton<_LogAction>(
            tooltip: '更多操作',
            enabled: !busy,
            onSelected: _action,
            itemBuilder: (_) => [
              if (!wide)
                const PopupMenuItem(
                  value: _LogAction.refresh,
                  child: Text('刷新'),
                ),
              if (!wide)
                const PopupMenuItem(
                  value: _LogAction.clear,
                  child: Text('清空日志'),
                ),
              const PopupMenuItem(value: _LogAction.about, child: Text('日志说明')),
            ],
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: CustomScrollView(
            key: const PageStorageKey('log-list'),
            slivers: [
              SliverToBoxAdapter(child: _filters(context, visible.length)),
              if (loading)
                const SliverToBoxAdapter(child: LinearProgressIndicator()),
              if (error != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        TextButton(
                          onPressed: busy ? null : _refresh,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (snapshot?.storageUnavailable == true)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text('日志存储不可用，仅显示本次运行的最近记录，仍可复制或导出。'),
                  ),
                ),
              if (unreadable > 0)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text('$unreadable 条记录无法解析，导出仍包含原始记录。'),
                  ),
                ),
              const SliverToBoxAdapter(child: Divider(height: 1)),
              if (visible.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        snapshot == null && busy
                            ? '正在读取日志…'
                            : entries.isEmpty
                            ? '暂无运行日志'
                            : '没有符合条件的日志',
                      ),
                    ),
                  ),
                )
              else
                SliverList.separated(
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, index) => LogEntryTile(
                    key: ValueKey(
                      'log-entry-${visible[index].time}-${visible[index].event}-${visible[index].index}',
                    ),
                    entry: visible[index],
                    onCopy: () => _copyEntry(visible[index]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
