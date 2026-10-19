import 'package:flutter/material.dart';
import '../data/library.dart';
import 'batch_download_dialog.dart';
import 'book_page.dart';
import 'home.dart';
import 'reader.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.library});
  final Library library;
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  DownloadedBooksSnapshot? downloads;
  bool loading = true, failed = false;
  int generation = 0;
  bool editing = false, operating = false, deleting = false;
  final selected = <String>{};
  List<DownloadedBook> get selectedBooks =>
      downloads?.books
          .where((entry) => selected.contains(entry.book.key))
          .toList() ??
      [];
  bool get canDownload =>
      selectedBooks.isNotEmpty &&
      selectedBooks.every(
        (entry) => widget.library.sourceFor(entry.book) != null,
      );

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(DownloadsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      selected.clear();
      editing = false;
      operating = false;
      deleting = false;
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final token = ++generation;
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final next = await widget.library.downloadedBooks();
      if (mounted && token == generation) {
        setState(() {
          downloads = next;
          selected.retainAll(next.books.map((entry) => entry.book.key));
          if (next.books.isEmpty) editing = false;
        });
      }
    } catch (_) {
      if (mounted && token == generation) setState(() => failed = true);
    } finally {
      if (mounted && token == generation) setState(() => loading = false);
    }
  }

  void _toggleSelection(String key) {
    if (operating) return;
    setState(() {
      editing = true;
      if (!selected.remove(key)) selected.add(key);
    });
  }

  void _exitSelection() => setState(() {
    editing = false;
    selected.clear();
  });

  Future<void> _downloadSelected() async {
    if (operating || !canDownload) return;
    final library = widget.library;
    final books = selectedBooks.map((entry) => entry.book).toList();
    setState(() => operating = true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => BatchDownloadDialog(library: library, books: books),
      );
      if (!mounted || widget.library != library) return;
      _exitSelection();
      await _refresh();
    } finally {
      if (mounted && widget.library == library) {
        setState(() => operating = false);
      }
    }
  }

  Future<void> _deleteSelected() async {
    if (operating || selected.isEmpty) return;
    final library = widget.library;
    final books = selectedBooks.map((entry) => entry.book).toList();
    final local = books.where((book) => book.source == 'local').length;
    setState(() => operating = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除本地下载'),
          content: SingleChildScrollView(
            child: Text(
              '将删除所选 ${books.length} 本书的本地正文、封面和插图，保留书架、最近阅读及阅读进度。'
              '${local > 0 ? '\n其中 $local 本为本地导入，删除后需重新导入原文件才能阅读。' : '\n在线书籍可在书架或作品详情中重新下载。'}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除下载'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || widget.library != library) return;
      setState(() => deleting = true);
      final failures = <String>[];
      var deleted = 0;
      for (final book in books) {
        if (!mounted || widget.library != library) return;
        try {
          await library.deleteDownloadedBook(book);
          if (!mounted || widget.library != library) return;
          deleted++;
          selected.remove(book.key);
        } catch (error) {
          failures.add('${book.title}（${library.sourceName(book)}）：$error');
        }
      }
      if (!mounted || widget.library != library) return;
      if (selected.isEmpty) _exitSelection();
      await _refresh();
      if (!mounted || widget.library != library) return;
      setState(() => deleting = false);
      if (failures.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已删除 $deleted 本书的本地下载')));
      } else {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('已删除 $deleted 本，${failures.length} 本删除失败'),
            content: SingleChildScrollView(child: Text(failures.join('\n'))),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted && widget.library == library) {
        setState(() {
          operating = false;
          deleting = false;
        });
      }
    }
  }

  Future<void> _open(DownloadedBook downloaded, {bool details = false}) async {
    final book = downloaded.book;
    final saved = widget.library.progress[book.key]?.firstOrNull;
    final resume =
        saved != null &&
        saved >= 0 &&
        saved < book.chapters.length &&
        downloaded.chapterIds.contains(book.chapters[saved].id);
    final firstCached = book.chapters.indexWhere(
      (chapter) => downloaded.chapterIds.contains(chapter.id),
    );
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => details
            ? BookPage(library: widget.library, book: book)
            : ReaderPage(
                library: widget.library,
                book: book,
                initialChapter: resume ? null : firstCached,
              ),
      ),
    );
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !editing && !operating,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && editing && !operating) _exitSelection();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(editing ? '已选 ${selected.length} 本' : '下载'),
        leading: editing
            ? IconButton(
                tooltip: '取消选择',
                onPressed: operating ? null : _exitSelection,
                icon: const Icon(Icons.close),
              )
            : null,
        actions: [
          if (editing)
            TextButton(
              onPressed: operating || loading
                  ? null
                  : () => setState(() {
                      final keys = downloads!.books
                          .map((entry) => entry.book.key)
                          .toSet();
                      if (selected.containsAll(keys)) {
                        selected.clear();
                      } else {
                        selected.addAll(keys);
                      }
                    }),
              child: Text(
                selected.length == downloads?.books.length ? '取消全选' : '全选',
              ),
            ),
        ],
      ),
      bottomNavigationBar: editing
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selected.isNotEmpty && !canDownload) ...[
                      const Text('选中项包含本地书籍或不可用书源，仅支持删除。'),
                      const SizedBox(height: 8),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            key: const ValueKey('download-selected'),
                            onPressed: operating || loading || !canDownload
                                ? null
                                : _downloadSelected,
                            icon: const Icon(Icons.download_outlined),
                            label: const Text('下载'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const ValueKey('delete-selected'),
                            onPressed: operating || loading || selected.isEmpty
                                ? null
                                : _deleteSelected,
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('删除'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Builder(
            builder: (context) {
              if (loading) {
                return const Center(child: CircularProgressIndicator());
              }
              if (failed) {
                return _notice('下载记录加载失败，请重试。');
              }
              final data = downloads!;
              if (data.books.isEmpty && data.unreadable == 0) {
                return _notice('暂无已下载的书籍\n可在作品详情中下载章节，阅读缓存和本地导入的书籍也会显示在这里。');
              }
              return Column(
                children: [
                  if (deleting)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('正在删除本地下载…'),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 12, 8),
                    child: Row(
                      children: [
                        Expanded(child: Text('已下载 ${data.books.length} 本')),
                        IconButton(
                          tooltip: '刷新下载记录',
                          onPressed: operating ? null : _refresh,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                  ),
                  if (data.unreadable > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        '${data.unreadable} 条下载记录读取失败，可刷新重试。',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                      itemCount: data.books.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, index) => _book(data.books[index]),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _notice(String message) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.download_outlined, size: 48),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: operating ? null : _refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新'),
          ),
        ],
      ),
    ),
  );

  Widget _book(DownloadedBook downloaded) {
    final book = downloaded.book;
    final count = downloaded.chapterIds.length;
    return Card(
      key: ValueKey('downloaded-book-${book.key}'),
      margin: EdgeInsets.zero,
      color: selected.contains(book.key)
          ? Theme.of(context).colorScheme.secondaryContainer
          : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: operating
            ? null
            : () => editing ? _toggleSelection(book.key) : _open(downloaded),
        onLongPress: operating
            ? null
            : () {
                if (!editing) _toggleSelection(book.key);
              },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 60,
                height: 90,
                child: BookCover(book: book, library: widget.library),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${book.author} · ${widget.library.sourceName(book)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '已下载 $count / ${book.chapters.length} 章'
                      '${count == book.chapters.length ? ' · 已全部下载' : ' · 部分下载'}',
                    ),
                  ],
                ),
              ),
              if (editing)
                Checkbox(
                  value: selected.contains(book.key),
                  onChanged: operating
                      ? null
                      : (_) => _toggleSelection(book.key),
                )
              else
                IconButton(
                  tooltip: '作品详情',
                  onPressed: operating
                      ? null
                      : () => _open(downloaded, details: true),
                  icon: const Icon(Icons.chevron_right),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
