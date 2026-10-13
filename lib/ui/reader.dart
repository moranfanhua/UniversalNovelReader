import 'dart:async';
import 'package:flutter/material.dart';
import '../data/library.dart';
import '../domain/models.dart';
import 'comments_sheet.dart';
import 'image_bytes.dart';
import 'paged_chapter.dart';
import 'reading_settings.dart';

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

class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  late int chapter;
  late Future<ChapterContent> content;
  final scroll = ScrollController();
  final viewport = GlobalKey();
  List<GlobalKey> keys = [];
  Timer? debounce;
  Timer? countDebounce;
  final commentCounts = <int, int>{};
  final countRequests = <int>{};
  final countErrors = <int>{};
  List<Paragraph> loadedParagraphs = [];
  bool restoring = false;
  int loadGeneration = 0;
  int paragraph = 0;
  bool leaving = false;
  bool settingsOpen = false;
  int characterOffset = 0;
  Set<int> pageRows = {};
  Library get library => widget.library;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final saved = library.progress[widget.book.key];
    chapter = (widget.initialChapter ?? saved?.first ?? 0).clamp(
      0,
      widget.book.chapters.length - 1,
    );
    paragraph = widget.initialChapter == null ? saved?.last ?? 0 : 0;
    characterOffset = widget.initialChapter == null
        ? library.pageOffsets[widget.book.key] ?? 0
        : 0;
    scroll.addListener(_track);
    _load();
  }

  void _load() {
    final generation = ++loadGeneration;
    restoring = true;
    keys = [];
    pageRows = {};
    loadedParagraphs = [];
    commentCounts.clear();
    countRequests.clear();
    countErrors.clear();
    countDebounce?.cancel();
    final target = paragraph;
    content = library.read(widget.book, widget.book.chapters[chapter]).then((
      value,
    ) {
      if (!mounted || generation != loadGeneration) return value;
      keys = List.generate(value.paragraphs.length, (_) => GlobalKey());
      loadedParagraphs = value.paragraphs;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || generation != loadGeneration) return;
        final index = target.clamp(0, keys.length - 1);
        final ctx = keys[index].currentContext;
        if (ctx != null) await Scrollable.ensureVisible(ctx, alignment: 0);
        restoring = false;
        _scheduleCounts();
      });
      return value;
    });
  }

  void _track() {
    if (settingsOpen) return;
    _scheduleCounts();
    if (restoring) return;
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      _savePosition().catchError((Object e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('进度保存失败：$e')));
        }
      });
    });
  }

  void _scheduleCounts() {
    if (widget.book.source != 'sfacg') return;
    countDebounce?.cancel();
    countDebounce = Timer(
      const Duration(milliseconds: 180),
      _loadVisibleCounts,
    );
  }

  void _loadVisibleCounts() {
    if (!mounted || restoring || countRequests.length >= 3) return;
    final visible = <int>{...pageRows};
    if (library.readingMode == ReadingMode.scroll) {
      final view = viewport.currentContext?.findRenderObject();
      if (view is! RenderBox) return;
      final top = view.localToGlobal(Offset.zero).dy - 150;
      final bottom = top + view.size.height + 300;
      for (var i = 0; i < keys.length; i++) {
        final box = keys[i].currentContext?.findRenderObject();
        final row = loadedParagraphs[i].remoteIndex;
        if (row == null || box is! RenderBox) continue;
        final y = box.localToGlobal(Offset.zero).dy;
        if (y < bottom && y + box.size.height > top) visible.add(row);
      }
    }
    final generation = loadGeneration;
    final target = widget.book.chapters[chapter];
    for (final row in visible) {
      if (countRequests.length >= 3) break;
      if (commentCounts.containsKey(row) ||
          countErrors.contains(row) ||
          !countRequests.add(row)) {
        continue;
      }
      library.source
          .commentCount(target, row)
          .then((count) {
            if (!mounted || generation != loadGeneration) return;
            setState(() => commentCounts[row] = count);
          })
          .catchError((Object error) {
            if (!mounted || generation != loadGeneration) return;
            setState(() => countErrors.add(row));
          })
          .whenComplete(() {
            if (!mounted || generation != loadGeneration) return;
            countRequests.remove(row);
            _scheduleCounts();
          });
    }
  }

  Future<void> _comments(Paragraph paragraph) async {
    final generation = loadGeneration;
    await showComments(
      context,
      library.source,
      widget.book.chapters[chapter],
      paragraph,
    );
    if (!mounted || generation != loadGeneration) return;
    setState(() {
      commentCounts.remove(paragraph.remoteIndex);
      countErrors.remove(paragraph.remoteIndex);
    });
    // Refresh only this row when returning from the discussion.
    try {
      final count = await library.source.commentCount(
        widget.book.chapters[chapter],
        paragraph.remoteIndex!,
        refresh: true,
      );
      if (mounted && generation == loadGeneration) {
        setState(() => commentCounts[paragraph.remoteIndex!] = count);
      }
    } catch (_) {
      if (mounted && generation == loadGeneration) {
        setState(() => countErrors.add(paragraph.remoteIndex!));
      }
    }
  }

  Widget _commentButton(Paragraph paragraph) => Tooltip(
    message: '阅读本段段评',
    child: TextButton(
      style: TextButton.styleFrom(
        minimumSize: const Size(40, 40),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        visualDensity: VisualDensity.compact,
      ),
      onPressed: () => _comments(paragraph),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.chat_bubble_outline, size: 16),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              commentCounts[paragraph.remoteIndex]?.toString() ??
                  (countErrors.contains(paragraph.remoteIndex) ? '?' : '…'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _savePosition() async {
    debounce?.cancel();
    if (!restoring &&
        !settingsOpen &&
        library.readingMode == ReadingMode.scroll) {
      characterOffset = 0;
      final viewBox = viewport.currentContext?.findRenderObject();
      final top = viewBox is RenderBox
          ? viewBox.localToGlobal(Offset.zero).dy
          : 0.0;
      for (var i = 0; i < keys.length; i++) {
        final box = keys[i].currentContext?.findRenderObject();
        if (box is RenderBox &&
            box.localToGlobal(Offset(0, box.size.height)).dy > top) {
          paragraph = i;
          break;
        }
      }
    }
    library.pageOffsets[widget.book.key] = characterOffset;
    await library.remember(widget.book, chapter, paragraph);
  }

  Future<void> _leave() async {
    if (leaving) return;
    leaving = true;
    try {
      await _savePosition();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('阅读进度保存失败：$e')));
      }
    } finally {
      leaving = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted) {
      unawaited(
        _savePosition().catchError((Object e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('阅读进度保存失败：$e')));
          }
        }),
      );
    }
  }

  void _go(int index) {
    if (index < 0 || index >= widget.book.chapters.length) return;
    debounce?.cancel();
    setState(() {
      chapter = index;
      paragraph = 0;
      characterOffset = 0;
      library.pageOffsets.remove(widget.book.key);
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

  Future<void> _settings() async {
    if (settingsOpen) return;
    try {
      final saving = _savePosition();
      settingsOpen = true;
      await saving;
      if (!mounted) return;
      final savedParagraph = paragraph, savedOffset = characterOffset;
      await showReadingSettings(context, library);
      if (!mounted) return;
      setState(() {
        paragraph = savedParagraph;
        characterOffset = savedOffset;
        _load();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('阅读设置打开失败：$e')));
      }
    } finally {
      settingsOpen = false;
    }
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
    countDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    debounce?.cancel();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_leave());
    },
    child: AnimatedBuilder(
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
              tooltip: '阅读设置',
              onPressed: _settings,
              icon: const Icon(Icons.settings_outlined),
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
            if (library.readingMode == ReadingMode.paged) {
              return PagedChapter(
                key: ValueKey(loadGeneration),
                content: snapshot.data!,
                title: widget.book.chapters[chapter].title,
                fontSize: library.fontSize,
                fontFamily: library.readingFontFamily,
                horizontalMargin: library.horizontalMargin,
                verticalMargin: library.verticalMargin,
                lineHeight: library.lineHeight,
                initialParagraph: paragraph,
                initialOffset: characterOffset,
                comments: widget.book.source == 'sfacg',
                onPosition: (index, offset, rows) {
                  if (settingsOpen) return;
                  paragraph = index;
                  characterOffset = offset;
                  pageRows = rows;
                  _track();
                },
                imageBuilder: (url) =>
                    BookImage(library: library, book: widget.book, url: url),
                commentBuilder: _commentButton,
              );
            }
            return SingleChildScrollView(
              key: viewport,
              controller: scroll,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      library.horizontalMargin,
                      library.verticalMargin,
                      library.horizontalMargin,
                      library.verticalMargin + 40,
                    ),
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
                                            fontFamily:
                                                library.readingFontFamily,
                                            height: library.lineHeight,
                                          ),
                                        ),
                                ),
                                if (widget.book.source == 'sfacg' &&
                                    paragraphs[i].remoteIndex != null)
                                  Tooltip(
                                    message: '阅读本段段评',
                                    child: TextButton(
                                      style: TextButton.styleFrom(
                                        minimumSize: const Size(40, 40),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                        ),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      onPressed: () => _comments(paragraphs[i]),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.chat_bubble_outline,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 3),
                                          Text(
                                            commentCounts[paragraphs[i]
                                                        .remoteIndex]
                                                    ?.toString() ??
                                                (countErrors.contains(
                                                      paragraphs[i].remoteIndex,
                                                    )
                                                    ? '?'
                                                    : '…'),
                                          ),
                                        ],
                                      ),
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
                  child: Text(
                    '${chapter + 1} / ${widget.book.chapters.length}',
                    textAlign: TextAlign.center,
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
      return ImageBytes(
        s.data!,
        errorBuilder: (_, error, stack) => const Text('无法显示此插图'),
      );
    },
  );
}
