import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../data/library.dart';
import '../data/app_log.dart';
import '../domain/models.dart';
import '../formats/ebook.dart';
import 'chapter_download_dialog.dart';
import 'reader.dart';
import 'home.dart';
import 'chapter_directory.dart';
import 'add_to_shelf_button.dart';

class BookPage extends StatefulWidget {
  const BookPage({super.key, required this.library, required this.book});
  final Library library;
  final Book book;
  @override
  State<BookPage> createState() => _BookPageState();
}

class _BookPageState extends State<BookPage> {
  late Book book = widget.book;
  late Future<Set<String>> cached = widget.library.cachedChapterIds(book);
  bool busy = false;
  String? error;
  int cacheRevision = 0;
  @override
  void initState() {
    super.initState();
    cacheRevision = widget.library.downloadQueue.cacheRevision;
    widget.library.downloadQueue.addListener(_downloadChanged);
  }

  void _downloadChanged() {
    final revision = widget.library.downloadQueue.cacheRevision;
    if (revision == cacheRevision) return;
    cacheRevision = revision;
    _refreshCached();
  }

  @override
  void dispose() {
    widget.library.downloadQueue.removeListener(_downloadChanged);
    super.dispose();
  }

  void _refreshCached() {
    if (!mounted) return;
    final next = widget.library.cachedChapterIds(book);
    setState(() {
      cached = next;
    });
  }

  Future<void> _export(bool epub) async {
    setState(() {
      busy = true;
      error = null;
    });
    File? exportFile;
    try {
      final data = await widget.library.cachedChapterIds(book);
      if (!mounted) return;
      if (data.isEmpty) throw const SourceException('请先阅读或下载需要导出的章节');
      if (data.length < book.chapters.length) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('导出已缓存章节'),
            content: Text(
              '当前已缓存 ${data.length} / ${book.chapters.length} 章。将按原目录顺序导出节选，并在文件名标注“节选”。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('导出节选'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }
      final Uint8List bytes;
      if (epub) {
        exportFile = await Ebook.exportEpubFile(
          book,
          (chapter) async {
            if (!data.contains(chapter.id)) return null;
            final content = await widget.library.cached(book, chapter);
            if (content == null) {
              throw const SourceException('缓存章节已变更，请重新导出');
            }
            return content;
          },
          (key) => widget.library.loadImage(book, key),
          isCancelled: () => !mounted,
        );
        bytes = await exportFile.readAsBytes();
      } else {
        bytes = Ebook.exportTxt(
          book,
          await widget.library.cachedContents(book),
        );
      }
      if (!mounted) return;
      final title = book.title.replaceAll(
        RegExp(r'[<>:"/\\|?*\x00-\x1f]'),
        '_',
      );
      final path = await FilePicker.saveFile(
        fileName:
            '${title.substring(0, title.length.clamp(0, 80))}${data.length < book.chapters.length ? '_节选' : ''}.${epub ? 'epub' : 'txt'}',
        bytes: bytes,
        mimeType: epub ? 'application/epub+zip' : 'text/plain',
        dialogTitle: '导出小说',
      );
      if (path != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('导出完成')));
      }
    } catch (e, stack) {
      AppLog.instance.record(
        LogLevel.error,
        'export.failed',
        error: e,
        stackTrace: stack,
      );
      if (mounted) setState(() => error = '$e');
    } finally {
      try {
        if (exportFile != null) await exportFile.parent.delete(recursive: true);
      } catch (e, stack) {
        AppLog.instance.record(
          LogLevel.warning,
          'export.cleanup_failed',
          error: e,
          stackTrace: stack,
        );
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final service = widget.library.sourceFor(book);
      if (service == null) throw const SourceException('当前作品的书源不可用');
      final next = await service.getBook(book.id);
      await widget.library.updateBook(next);
      if (mounted) {
        setState(() {
          book = next;
          cached = widget.library.cachedChapterIds(next);
        });
      }
    } catch (e, stack) {
      AppLog.instance.record(
        LogLevel.error,
        'book.refresh_failed',
        error: e,
        stackTrace: stack,
      );
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('作品详情'),
      actions: [
        if (widget.library.sourceFor(book) != null)
          IconButton(
            tooltip: '刷新目录',
            onPressed: busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
      ],
    ),
    body: Column(
      children: [
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          MaterialBanner(
            content: Text(error!),
            actions: [
              TextButton(
                onPressed: () => setState(() => error = null),
                child: const Text('关闭'),
              ),
            ],
          ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 100,
                                height: 150,
                                child: BookCover(
                                  book: book,
                                  library: widget.library,
                                ),
                              ),
                              const SizedBox(width: 20),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      book.title,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.headlineSmall,
                                    ),
                                    const SizedBox(height: 12),
                                    Text(book.author),
                                    const SizedBox(height: 8),
                                    Text(
                                      '${book.chapters.length} 章 · ${widget.library.sourceName(book)}',
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (book.description.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 20),
                              child: Text(book.description),
                            ),
                          const SizedBox(height: 24),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              FilledButton.icon(
                                onPressed: busy
                                    ? null
                                    : () async {
                                        await Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => ReaderPage(
                                              library: widget.library,
                                              book: book,
                                            ),
                                          ),
                                        );
                                        _refreshCached();
                                      },
                                icon: const Icon(Icons.menu_book),
                                label: Text(
                                  widget
                                              .library
                                              .progress[book.key]
                                              ?.isNotEmpty ==
                                          true
                                      ? '继续阅读'
                                      : '开始阅读',
                                ),
                              ),
                              AddToShelfButton(
                                library: widget.library,
                                book: book,
                                enabled: !busy,
                              ),
                              if (widget.library.sourceFor(book) != null)
                                OutlinedButton.icon(
                                  onPressed: busy
                                      ? null
                                      : () async {
                                          await showChapterDownloadDialog(
                                            context,
                                            library: widget.library,
                                            book: book,
                                          );
                                          _refreshCached();
                                        },
                                  icon: const Icon(Icons.download_outlined),
                                  label: const Text('下载章节'),
                                ),
                              OutlinedButton(
                                onPressed: busy ? null : () => _export(true),
                                child: const Text('导出 EPUB'),
                              ),
                              OutlinedButton(
                                onPressed: busy ? null : () => _export(false),
                                child: const Text('导出 TXT'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          FutureBuilder(
                            future: cached,
                            builder: (context, s) => Text(
                              s.hasData
                                  ? '目录 · 已缓存 ${s.data!.length} / ${book.chapters.length} 章'
                                  : '目录',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  FutureBuilder<Set<String>>(
                    future: cached,
                    builder: (context, snapshot) => ChapterDirectory(
                      chapters: book.chapters,
                      cachedChapterIds: snapshot.data ?? {},
                      selectedChapter:
                          widget.library.progress[book.key]?.firstOrNull,
                      enabled: !busy,
                      onChapterSelected: (i) async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ReaderPage(
                              library: widget.library,
                              book: book,
                              initialChapter: i,
                            ),
                          ),
                        );
                        _refreshCached();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
