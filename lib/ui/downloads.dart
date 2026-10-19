import 'package:flutter/material.dart';
import '../data/library.dart';
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

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(DownloadsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) _refresh();
  }

  Future<void> _refresh() async {
    final token = ++generation;
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final next = await widget.library.downloadedBooks();
      if (mounted && token == generation) setState(() => downloads = next);
    } catch (_) {
      if (mounted && token == generation) setState(() => failed = true);
    } finally {
      if (mounted && token == generation) setState(() => loading = false);
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('下载')),
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 12, 8),
                  child: Row(
                    children: [
                      Expanded(child: Text('已下载 ${data.books.length} 本')),
                      IconButton(
                        tooltip: '刷新下载记录',
                        onPressed: _refresh,
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
            onPressed: _refresh,
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
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(downloaded),
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
              IconButton(
                tooltip: '作品详情',
                onPressed: () => _open(downloaded, details: true),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
