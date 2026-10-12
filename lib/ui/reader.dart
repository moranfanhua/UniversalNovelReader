import 'dart:async';
import 'package:flutter/material.dart';
import '../data/library.dart';
import '../domain/models.dart';
import 'comments_sheet.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.library,
    required this.book,
    this.initialChapter,
  });
  final Library library;
  final Book book;
  final int? initialChapter;
  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late int chapter;
  late Future<ChapterContent> content;
  final scroll = ScrollController();
  List<GlobalKey> keys = [];
  Timer? debounce;
  bool restoring = false;
  int loadGeneration = 0;
  int paragraph = 0;
  Library get library => widget.library;
  @override
  void initState() {
    super.initState();
    final saved = library.progress[widget.book.key];
    chapter = (widget.initialChapter ?? saved?.first ?? 0).clamp(
      0,
      widget.book.chapters.length - 1,
    );
    paragraph = widget.initialChapter == null ? saved?.last ?? 0 : 0;
    scroll.addListener(_track);
    _load();
  }

  void _load() {
    final generation = ++loadGeneration;
    restoring = true;
    keys = [];
    final target = paragraph;
    content = library.read(widget.book, widget.book.chapters[chapter]).then((
      value,
    ) {
      if (!mounted || generation != loadGeneration) return value;
      keys = List.generate(value.paragraphs.length, (_) => GlobalKey());
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || generation != loadGeneration) return;
        final index = target.clamp(0, keys.length - 1);
        final ctx = keys[index].currentContext;
        if (ctx != null) await Scrollable.ensureVisible(ctx, alignment: 0);
        restoring = false;
      });
      return value;
    });
  }

  void _track() {
    if (restoring) return;
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      for (var i = 0; i < keys.length; i++) {
        final box = keys[i].currentContext?.findRenderObject();
        if (box is RenderBox &&
            box.localToGlobal(Offset(0, box.size.height)).dy > 140) {
          paragraph = i;
          break;
        }
      }
      library.remember(widget.book, chapter, paragraph).catchError((Object e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('进度保存失败：$e')));
        }
      });
    });
  }

  void _go(int index) {
    if (index < 0 || index >= widget.book.chapters.length) return;
    debounce?.cancel();
    setState(() {
      chapter = index;
      paragraph = 0;
      if (scroll.hasClients) scroll.jumpTo(0);
      _load();
    });
    library.remember(widget.book, chapter, 0).catchError((Object e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    });
  }

  Future<void> _directory() async {
    final index = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                widget.book.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: widget.book.chapters.length,
                itemBuilder: (context, i) => ListTile(
                  selected: i == chapter,
                  title: Text(widget.book.chapters[i].title),
                  leading: Text('${i + 1}'),
                  trailing: widget.book.chapters[i].vip
                      ? const Icon(Icons.lock_outline, size: 18)
                      : null,
                  onTap: () => Navigator.pop(context, i),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (index != null && mounted) _go(index);
  }

  void _preferences() {
    library.save().catchError((Object e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    });
  }

  @override
  void dispose() {
    debounce?.cancel();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: library,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(
          widget.book.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '目录',
            onPressed: _directory,
            icon: const Icon(Icons.format_list_bulleted),
          ),
          IconButton(
            tooltip: '字号减小',
            onPressed: () {
              library.fontSize = (library.fontSize - 2).clamp(14, 32);
              _preferences();
            },
            icon: const Icon(Icons.text_decrease),
          ),
          IconButton(
            tooltip: '字号增大',
            onPressed: () {
              library.fontSize = (library.fontSize + 2).clamp(14, 32);
              _preferences();
            },
            icon: const Icon(Icons.text_increase),
          ),
          IconButton(
            tooltip: '日夜模式',
            onPressed: () {
              library.night = !library.night;
              _preferences();
            },
            icon: Icon(
              library.night
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
            ),
          ),
        ],
      ),
      body: FutureBuilder<ChapterContent>(
        future: content,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 48),
                    const SizedBox(height: 16),
                    Text('${snapshot.error}', textAlign: TextAlign.center),
                    TextButton(
                      onPressed: () => setState(_load),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            );
          }
          if (snapshot.connectionState != ConnectionState.done ||
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final paragraphs = snapshot.data!.paragraphs;
          return SingleChildScrollView(
            controller: scroll,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 24, 16, 64),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        widget.book.chapters[chapter].title,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 32),
                      for (var i = 0; i < paragraphs.length; i++)
                        Padding(
                          key: keys[i],
                          padding: const EdgeInsets.only(bottom: 18),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: paragraphs[i].image != null
                                    ? BookImage(
                                        library: library,
                                        book: widget.book,
                                        url: paragraphs[i].image!,
                                      )
                                    : SelectableText(
                                        '　　${paragraphs[i].text}',
                                        style: TextStyle(
                                          fontSize: library.fontSize,
                                          height: 1.9,
                                        ),
                                      ),
                              ),
                              if (widget.book.source == 'sfacg' &&
                                  paragraphs[i].remoteIndex != null)
                                IconButton(
                                  tooltip: '阅读本段段评',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => showComments(
                                    context,
                                    library.source,
                                    widget.book.chapters[chapter],
                                    paragraphs[i],
                                  ),
                                  icon: const Icon(
                                    Icons.chat_bubble_outline,
                                    size: 18,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: chapter > 0 ? () => _go(chapter - 1) : null,
                icon: const Icon(Icons.chevron_left),
                label: const Text('上一章'),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    '${chapter + 1} / ${widget.book.chapters.length}',
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: chapter + 1 < widget.book.chapters.length
                    ? () => _go(chapter + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
                label: const Text('下一章'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class BookImage extends StatefulWidget {
  const BookImage({
    super.key,
    required this.library,
    required this.book,
    required this.url,
  });
  final Library library;
  final Book book;
  final String url;
  @override
  State<BookImage> createState() => _BookImageState();
}

class _BookImageState extends State<BookImage> {
  late var bytes = widget.library.loadImage(widget.book, widget.url);
  @override
  void didUpdateWidget(BookImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      bytes = widget.library.loadImage(widget.book, widget.url);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: bytes,
    builder: (context, s) {
      if (s.hasError) {
        return TextButton.icon(
          onPressed: () => setState(
            () => bytes = widget.library.loadImage(widget.book, widget.url),
          ),
          icon: const Icon(Icons.broken_image_outlined),
          label: const Text('插图加载失败，点击重试'),
        );
      }
      if (!s.hasData) {
        return const SizedBox(
          height: 120,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return Image.memory(
        s.data!,
        errorBuilder: (_, error, stack) => const Text('无法显示此插图'),
      );
    },
  );
}
