import 'package:flutter/material.dart';
import '../data/library.dart';
import '../domain/models.dart';
import '../domain/bookshelf.dart';
import '../sources/bookshelf_source.dart';
import 'account.dart';
import 'platform_order.dart';
import 'source_icon.dart';

class ImportShelfPage extends StatefulWidget {
  const ImportShelfPage({super.key, required this.library});
  final Library library;
  @override
  State<ImportShelfPage> createState() => _ImportShelfPageState();
}

class _ImportShelfPageState extends State<ImportShelfPage> {
  final name = TextEditingController();
  BookshelfSource? source;
  List<RemoteBookshelf>? shelves;
  RemoteBookshelf? selected;
  List<String>? ids;
  final loaded = <String, Book>{};
  final failures = <String>[];
  bool busy = false;
  bool cancelled = false, saving = false;
  String? error;
  int completed = 0, total = 0;
  Library get library => widget.library;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> _load(BookshelfSource service) async {
    if (busy) return;
    setState(() {
      source = service;
      shelves = null;
      busy = true;
      error = null;
    });
    try {
      final result = await service.getShelves();
      if (mounted) setState(() => shelves = result);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  bool _validName() {
    final value = name.text.trim();
    if (value.isEmpty ||
        value == '全部作品' ||
        value == '最近阅读' ||
        library.shelves.any((s) => s.name == value)) {
      setState(() => error = value.isEmpty ? '请填写书架名称' : '书架名称已存在，请使用其他名称');
      return false;
    }
    return true;
  }

  Future<void> _import() async {
    if (busy || !_validName()) return;
    setState(() {
      busy = true;
      error = null;
      failures.clear();
      completed = 0;
      cancelled = false;
    });
    try {
      final service = source!;
      ids ??= (await service.getShelfBookIds(selected!)).toSet().toList();
      if (!mounted || cancelled) return;
      final existing = {
        for (final book in library.recentBooks) book.key: book,
        for (final book in library.books) book.key: book,
      };
      for (final id in ids!) {
        final book = existing['${service.id}:$id'];
        if (book != null) loaded[id] = book;
      }
      setState(() {
        total = ids!.length;
        completed = loaded.length;
      });
      final pending = ids!.where((id) => !loaded.containsKey(id)).toList();
      final batchSize = service.shelfBookBatchSize;
      if (batchSize <= 0) throw const SourceException('书源的作品批量大小无效');
      for (var offset = 0; offset < pending.length; offset += batchSize) {
        if (!mounted || cancelled) return;
        final batch = pending.skip(offset).take(batchSize).toList();
        try {
          final results = await service.getShelfBooks(batch);
          if (!mounted || cancelled) return;
          final byId = <String, ShelfBookResult>{};
          for (final result in results) {
            if (!batch.contains(result.id) || byId.containsKey(result.id)) {
              throw const SourceException('平台返回了无效或重复的作品');
            }
            byId[result.id] = result;
          }
          for (final id in batch) {
            final result = byId[id];
            final book = result?.book;
            if (book == null) {
              failures.add('$id：${result?.error ?? '平台未返回作品详情'}');
            } else if (book.source != service.id || book.id != id) {
              failures.add('$id：平台返回了其他作品');
            } else {
              loaded[id] = book;
            }
          }
        } catch (e) {
          if (!mounted || cancelled) return;
          failures.addAll(batch.map((id) => '$id：$e'));
        }
        if (!mounted || cancelled) return;
        setState(() => completed += batch.length);
      }
      if (failures.isNotEmpty) {
        setState(
          () => error =
              '${failures.length} 本作品获取失败，可重试或仅导入已获取的 ${loaded.length} 本。',
        );
      } else {
        await _save();
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _save() async {
    if (cancelled) return;
    setState(() => saving = true);
    try {
      final result = await library.importShelf(
        name: name.text,
        source: source!,
        remote: selected!,
        imported: ids!
            .where(loaded.containsKey)
            .map((id) => loaded[id]!)
            .toList(),
      );
      if (mounted) Navigator.pop(context, result);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _savePartial() async {
    if (!_validName()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await _save();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _back() {
    if (selected != null) {
      setState(() {
        selected = null;
        ids = null;
        loaded.clear();
        failures.clear();
        error = null;
      });
    } else if (source != null) {
      setState(() {
        source = null;
        shelves = null;
        error = null;
      });
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<Bookshelf>(
    canPop: !busy && source == null,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && !busy) _back();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          selected != null
              ? '命名书架'
              : source != null
              ? '选择书架'
              : '选择平台',
        ),
        leading: IconButton(
          tooltip: '返回',
          onPressed: busy ? null : _back,
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (busy) ...[
                LinearProgressIndicator(
                  value: selected != null && total > 0
                      ? completed / total
                      : null,
                ),
                const SizedBox(height: 12),
                Text(
                  saving
                      ? '正在保存书架'
                      : selected != null
                      ? '正在获取作品 $completed/$total'
                      : '正在读取书架',
                ),
                if (!saving)
                  TextButton(
                    onPressed: () {
                      cancelled = true;
                      Navigator.pop(context);
                    },
                    child: const Text('取消导入'),
                  ),
                const SizedBox(height: 16),
              ],
              if (error != null) ...[
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 16),
              ],
              if (source == null)
                for (final service in platformDisplayOrder(
                  library.bookshelfSources,
                ))
                  Card(
                    child: ListTile(
                      leading: SourceIcon(service.id, size: 40),
                      title: Text(service.name),
                      subtitle: Text(
                        service.hasSession ? '读取已登录账号的书架' : '需要先登录',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _load(service),
                    ),
                  ),
              if (source != null && selected == null && !busy) ...[
                if (shelves?.isEmpty == true) const Text('这个账号暂无可导入的小说书架。'),
                for (final shelf in shelves ?? <RemoteBookshelf>[])
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.library_books_outlined),
                      title: Text(shelf.name),
                      subtitle: shelf.bookIds == null
                          ? null
                          : Text('${shelf.bookIds!.length} 本作品'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => setState(() {
                        selected = shelf;
                        name.text = '${source!.name} · ${shelf.name}';
                        error = null;
                      }),
                    ),
                  ),
                if (error != null || shelves?.isEmpty == true)
                  OutlinedButton(
                    onPressed: () => _load(source!),
                    child: const Text('重新读取书架'),
                  ),
                if (error != null)
                  TextButton(
                    onPressed: () async {
                      await Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AccountSettingsPage(library: library),
                        ),
                      );
                      if (mounted) await _load(source!);
                    },
                    child: const Text('前往账号设置'),
                  ),
              ],
              if (selected != null) ...[
                Text('${source!.name} / ${selected!.name}'),
                const SizedBox(height: 20),
                TextField(
                  key: const ValueKey('import-shelf-name'),
                  controller: name,
                  enabled: !busy,
                  maxLength: 40,
                  decoration: const InputDecoration(
                    labelText: '书架名称',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: busy ? null : (_) => _import(),
                ),
                const SizedBox(height: 12),
                const Text('导入作品基本信息，目录在打开作品时加载，正文可在阅读时获取或在作品页面下载。'),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: busy ? null : _import,
                  child: Text(failures.isEmpty ? '导入' : '重试失败作品'),
                ),
                if (failures.isNotEmpty && loaded.isNotEmpty)
                  OutlinedButton(
                    onPressed: busy ? null : _savePartial,
                    child: Text('仅导入已获取的 ${loaded.length} 本'),
                  ),
                for (final failure in failures)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(failure),
                  ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
