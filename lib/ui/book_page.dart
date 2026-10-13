import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../data/library.dart';
import '../domain/models.dart';
import '../formats/ebook.dart';
import 'reader.dart';
import 'home.dart';

class BookPage extends StatefulWidget {
  const BookPage({super.key, required this.library, required this.book});
  final Library library;
  final Book book;
  @override
  State<BookPage> createState() => _BookPageState();
}

class _BookPageState extends State<BookPage> {
  late Book book = widget.book;
  late Future<Map<String, ChapterContent>> cached = widget.library
      .cachedContents(book);
  bool busy = false;
  String? error;
  void _refreshCached() {
    if (!mounted) return;
    final next = widget.library.cachedContents(book);
    setState(() {
      cached = next;
    });
  }

  Future<void> _export(bool epub) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await widget.library.cachedContents(book);
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
      final bytes = epub
          ? await Ebook.exportEpub(
              book,
              data,
              (key) => widget.library.loadImage(book, key),
            )
          : Ebook.exportTxt(book, data);
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
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final next = await widget.library.source.getBook(book.id);
      await widget.library.add(next);
      if (mounted) {
        setState(() {
          book = next;
          cached = widget.library.cachedContents(next);
        });
      }
    } catch (e) {
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
        if (book.source == 'sfacg')
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
                                      '${book.chapters.length} 章 · ${book.source == 'sfacg' ? '菠萝包轻小说' : '本地小说'}',
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
                                label: const Text('继续阅读'),
                              ),
                              if (book.source == 'sfacg')
                                OutlinedButton.icon(
                                  onPressed: busy
                                      ? null
                                      : () async {
                                          await showDialog<void>(
                                            context: context,
                                            barrierDismissible: false,
                                            builder: (_) => DownloadDialog(
                                              library: widget.library,
                                              book: book,
                                            ),
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
                  SliverList.builder(
                    itemCount: book.chapters.length,
                    itemBuilder: (context, i) {
                      final c = book.chapters[i];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 24,
                        ),
                        leading: Text('${i + 1}'),
                        title: Text(c.title),
                        subtitle: Text(c.volume),
                        trailing: c.vip
                            ? const Icon(Icons.lock_outline, size: 18)
                            : null,
                        onTap: busy
                            ? null
                            : () async {
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
                      );
                    },
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

class DownloadDialog extends StatefulWidget {
  const DownloadDialog({super.key, required this.library, required this.book});
  final Library library;
  final Book book;
  @override
  State<DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<DownloadDialog> {
  final start = TextEditingController(text: '1');
  late final end = TextEditingController(
    text: '${widget.book.chapters.length}',
  );
  bool running = false, cancelled = false;
  int done = 0, total = 0, success = 0;
  String status = '选择需要保存到本机的章节范围';
  final failures = <String>[];
  @override
  void dispose() {
    start.dispose();
    end.dispose();
    super.dispose();
  }

  Future<void> _run() async {
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
    });
    for (var i = from - 1; i < to; i++) {
      if (cancelled) break;
      final c = widget.book.chapters[i];
      setState(() => status = c.title);
      try {
        final content = await widget.library.read(widget.book, c);
        await widget.library.cacheImages(widget.book, content);
        success++;
      } catch (e) {
        failures.add('${c.title}：$e');
      }
      if (!mounted) return;
      setState(() => done++);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (mounted) {
      setState(() {
        running = false;
        status =
            '${cancelled ? '已停止' : '下载完成'} · 成功 $success 章，失败 ${failures.length} 章';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !running,
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
                      enabled: !running,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '起始章'),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: TextField(
                      controller: end,
                      enabled: !running,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '结束章'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(status),
              if (total > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: LinearProgressIndicator(value: done / total),
                ),
              const SizedBox(height: 12),
              const Text(
                '已缓存正文会继续使用。付费章节需要已有权限，失败章节可再次下载。',
                style: TextStyle(fontSize: 12),
              ),
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
                : () => setState(() => cancelled = true),
            child: Text(cancelled ? '正在停止…' : '停止下载'),
          )
        else
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        FilledButton(
          onPressed: running ? null : _run,
          child: Text(done == 0 ? '开始下载' : '重新下载'),
        ),
      ],
    ),
  );
}
