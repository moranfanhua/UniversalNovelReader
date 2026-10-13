import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/library.dart';
import '../domain/models.dart';
import '../sources/comment_source.dart';
import 'comments_sheet.dart';
import 'image_bytes.dart';
import 'paged_chapter.dart';
import 'reading_settings.dart';
import 'reading_layout.dart';
import 'boundary_scroll.dart';
import 'volume_page_turner.dart';
import 'reading_tap_zones.dart';

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
  GlobalKey<PagedChapterState> pagedKey = GlobalKey<PagedChapterState>();
  List<GlobalKey> keys = [];
  Timer? debounce;
  Timer? countDebounce;
  Timer? chapterCooldown;
  final commentCounts = <(int, int), int>{};
  final countRequests = <(int, int)>{};
  final countErrors = <(int, int)>{};
  List<Paragraph> loadedParagraphs = [];
  bool restoring = false;
  int loadGeneration = 0;
  int paragraph = 0;
  bool leaving = false;
  bool turningPage = false;
  bool settingsOpen = false;
  bool openAtEnd = false, pagedStartAtEnd = false;
  bool restoreScheduled = false, restoreAtEnd = false;
  int restoreParagraph = 0;
  int characterOffset = 0;
  Set<int> pageRows = {};
  Set<int> previewRows = {};
  ChapterContent? previewContent;
  bool skipFirstPage = false;
  String _entryKey(int chapter) => '${widget.book.key}:$chapter';
  Library get library => widget.library;
  CommentSource? get comments => library.commentsFor(widget.book);
  CommentLocation _commentLocation(Paragraph paragraph, {int? chapterIndex}) =>
      CommentLocation(
        book: widget.book,
        chapter: widget.book.chapters[chapterIndex ?? chapter],
        paragraph: paragraph,
      );
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
    skipFirstPage =
        widget.initialChapter == null &&
        library.pagedChapterEntries[_entryKey(chapter)]?.firstOrNull == 1;
    if (widget.initialChapter != null) {
      library.pagedChapterEntries[_entryKey(chapter)] = [0];
    }
    scroll.addListener(_track);
    _load();
  }

  void _load() {
    final generation = ++loadGeneration;
    restoring = true;
    pagedKey = GlobalKey<PagedChapterState>();
    restoreScheduled = false;
    keys = [];
    pageRows = {};
    previewRows = {};
    previewContent = null;
    loadedParagraphs = [];
    commentCounts.clear();
    countRequests.clear();
    countErrors.clear();
    countDebounce?.cancel();
    restoreParagraph = paragraph;
    final atEnd = openAtEnd;
    restoreAtEnd = atEnd;
    pagedStartAtEnd = atEnd;
    content = library.read(widget.book, widget.book.chapters[chapter]).then((
      value,
    ) {
      if (!mounted || generation != loadGeneration) return value;
      keys = List.generate(value.paragraphs.length, (_) => GlobalKey());
      loadedParagraphs = value.paragraphs;
      openAtEnd = false;
      if (atEnd && value.paragraphs.isNotEmpty) {
        paragraph = value.paragraphs.length - 1;
        characterOffset = value.paragraphs.last.text.length;
      }
      return value;
    });
  }

  void _restorePosition() {
    if (!restoring || restoreScheduled) return;
    restoreScheduled = true;
    final generation = loadGeneration;
    // Schedule from the completed FutureBuilder, after its scroll viewport has
    // been attached and laid out, rather than from the data fetch callback.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != loadGeneration) return;
      if (restoreAtEnd && scroll.hasClients) {
        scroll.jumpTo(scroll.position.maxScrollExtent);
      } else if (keys.isNotEmpty) {
        final index = restoreParagraph.clamp(0, keys.length - 1);
        final ctx = keys[index].currentContext;
        if (ctx != null) await Scrollable.ensureVisible(ctx, alignment: 0);
      }
      if (!mounted || generation != loadGeneration) return;
      restoring = false;
      _track();
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
    if (comments?.commentCapabilities.counts != true) return;
    countDebounce?.cancel();
    countDebounce = Timer(
      const Duration(milliseconds: 180),
      _loadVisibleCounts,
    );
  }

  void _loadVisibleCounts() {
    final service = comments;
    if (!mounted ||
        restoring ||
        countRequests.length >= 3 ||
        service?.commentCapabilities.counts != true) {
      return;
    }
    final visible = <(int, int)>{
      for (final row in pageRows) (chapter, row),
      for (final row in previewRows) (chapter + 1, row),
    };
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
        if (y < bottom && y + box.size.height > top) {
          visible.add((chapter, row));
        }
      }
    }
    final generation = loadGeneration;
    for (final location in visible) {
      if (countRequests.length >= 3) break;
      if (commentCounts.containsKey(location) ||
          countErrors.contains(location) ||
          !countRequests.add(location)) {
        continue;
      }
      service!
          .paragraphCommentCount(
            _commentLocation(
              (location.$1 == chapter
                      ? loadedParagraphs
                      : previewContent!.paragraphs)
                  .firstWhere(
                    (paragraph) => paragraph.remoteIndex == location.$2,
                  ),
              chapterIndex: location.$1,
            ),
          )
          .then((count) {
            if (!mounted || generation != loadGeneration) return;
            setState(() => commentCounts[location] = count);
          })
          .catchError((Object error) {
            if (!mounted || generation != loadGeneration) return;
            setState(() => countErrors.add(location));
          })
          .whenComplete(() {
            if (!mounted || generation != loadGeneration) return;
            countRequests.remove(location);
            _scheduleCounts();
          });
    }
  }

  Future<void> _comments(Paragraph paragraph, {int? chapterIndex}) async {
    final index = chapterIndex ?? chapter;
    final location = (index, paragraph.remoteIndex ?? -1);
    final service = comments;
    if (service == null || paragraph.remoteIndex == null) return;
    final generation = loadGeneration;
    await showComments(
      context,
      service,
      widget.book.chapters[index],
      paragraph,
      book: widget.book,
    );
    if (!mounted ||
        generation != loadGeneration ||
        !service.commentCapabilities.counts) {
      return;
    }
    setState(() {
      commentCounts.remove(location);
      countErrors.remove(location);
    });
    // Refresh only this row when returning from the discussion.
    try {
      final count = await service.paragraphCommentCount(
        _commentLocation(paragraph, chapterIndex: index),
        refresh: true,
      );
      if (mounted && generation == loadGeneration) {
        setState(() => commentCounts[location] = count);
      }
    } catch (_) {
      if (mounted && generation == loadGeneration) {
        setState(() => countErrors.add(location));
      }
    }
  }

  Widget _commentButton(Paragraph paragraph, {int? chapterIndex}) => Tooltip(
    message: '阅读本段段评',
    child: TextButton(
      style: TextButton.styleFrom(
        minimumSize: const Size(40, 40),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        visualDensity: VisualDensity.compact,
      ),
      onPressed: () => _comments(paragraph, chapterIndex: chapterIndex),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.chat_bubble_outline, size: 16),
          if (comments?.commentCapabilities.counts == true)
            const SizedBox(width: 3),
          if (comments?.commentCapabilities.counts == true)
            Flexible(
              child: Text(
                commentCounts[(chapterIndex ?? chapter, paragraph.remoteIndex)]
                        ?.toString() ??
                    (countErrors.contains((
                          chapterIndex ?? chapter,
                          paragraph.remoteIndex,
                        ))
                        ? '?'
                        : '…'),
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

  void _stepChapter(int delta) {
    if (restoring || leaving || settingsOpen) return;
    if (chapterCooldown?.isActive == true) return;
    final target = chapter + delta;
    if (target < 0 || target >= widget.book.chapters.length) return;
    chapterCooldown = Timer(const Duration(milliseconds: 400), () {});
    _go(target, atEnd: delta < 0);
  }

  Future<ChapterPreview> _previewNextChapter() async {
    final index = chapter + 1;
    final generation = loadGeneration;
    final value = await library.read(widget.book, widget.book.chapters[index]);
    if (mounted && generation == loadGeneration) previewContent = value;
    return ChapterPreview(
      content: value,
      title: widget.book.chapters[index].title,
      hasFollowingChapter: index + 1 < widget.book.chapters.length,
      commentBuilder: (paragraph) =>
          _commentButton(paragraph, chapterIndex: index),
    );
  }

  void _advancePaged([ChapterContinuation? next]) {
    if (restoring ||
        leaving ||
        settingsOpen ||
        chapterCooldown?.isActive == true) {
      return;
    }
    final target = chapter + (next?.skipChapter == true ? 2 : 1);
    if (target >= widget.book.chapters.length) return;
    chapterCooldown = Timer(const Duration(milliseconds: 400), () {});
    library.pagedChapterEntries[_entryKey(target)] = [
      next?.skipFirstPage == true ? 1 : 0,
      chapter,
      skipFirstPage ? 1 : 0,
    ];
    _go(
      target,
      initialParagraph: next?.paragraph ?? 0,
      initialOffset: next?.offset ?? 0,
      skipFirst: next?.skipFirstPage == true,
      keepPagedEntry: true,
    );
  }

  void _previousPaged() {
    if (restoring ||
        leaving ||
        settingsOpen ||
        chapterCooldown?.isActive == true) {
      return;
    }
    final entry = library.pagedChapterEntries[_entryKey(chapter)];
    final target = entry != null && entry.length >= 3 ? entry[1] : chapter - 1;
    if (target < 0 || target >= chapter) return;
    final skip = entry != null && entry.length >= 3
        ? entry[2] == 1
        : library.pagedChapterEntries[_entryKey(target)]?.firstOrNull == 1;
    chapterCooldown = Timer(const Duration(milliseconds: 400), () {});
    _go(target, atEnd: true, skipFirst: skip, keepPagedEntry: true);
  }

  Future<void> _turnPage(int delta) async {
    if (restoring ||
        leaving ||
        settingsOpen ||
        turningPage ||
        loadedParagraphs.isEmpty ||
        ModalRoute.isCurrentOf(context) != true) {
      return;
    }
    turningPage = true;
    try {
      if (library.readingMode == ReadingMode.paged) {
        await pagedKey.currentState?.turnPage(delta);
      } else if (scroll.hasClients) {
        final position = scroll.position;
        final atBoundary = delta < 0
            ? position.extentBefore <= .5
            : position.extentAfter <= .5;
        if (atBoundary) {
          _stepChapter(delta);
        } else {
          final distance =
              (position.viewportDimension -
                      library.fontSize * library.lineHeight)
                  .clamp(1.0, double.infinity);
          await scroll.animateTo(
            (scroll.offset + distance * delta).clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        }
      }
    } finally {
      turningPage = false;
    }
  }

  void _go(
    int index, {
    bool atEnd = false,
    int initialParagraph = 0,
    int initialOffset = 0,
    bool skipFirst = false,
    bool keepPagedEntry = false,
  }) {
    if (index < 0 || index >= widget.book.chapters.length) return;
    debounce?.cancel();
    setState(() {
      chapter = index;
      paragraph = initialParagraph;
      characterOffset = initialOffset;
      skipFirstPage = skipFirst;
      if (!keepPagedEntry) library.pagedChapterEntries[_entryKey(index)] = [0];
      openAtEnd = atEnd;
      library.pageOffsets.remove(widget.book.key);
      if (initialOffset > 0) {
        library.pageOffsets[widget.book.key] = initialOffset;
      }
      _load();
      if (scroll.hasClients) scroll.jumpTo(0);
    });
    library.remember(widget.book, chapter, initialParagraph).catchError((
      Object e,
    ) {
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
    chapterCooldown?.cancel();
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
      builder: (context, _) => VolumePageTurner(
        enabled: library.volumeKeyPaging,
        onTurn: (delta) => unawaited(_turnPage(delta)),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.pageUp): () =>
                unawaited(_turnPage(-1)),
            const SingleActivator(LogicalKeyboardKey.pageDown): () =>
                unawaited(_turnPage(1)),
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                unawaited(_turnPage(-1)),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                unawaited(_turnPage(-1)),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                unawaited(_turnPage(1)),
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                unawaited(_turnPage(1)),
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
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
                            Text(
                              '${snapshot.error}',
                              textAlign: TextAlign.center,
                            ),
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
                  _restorePosition();
                  if (library.readingMode == ReadingMode.paged) {
                    return PagedChapter(
                      key: pagedKey,
                      content: snapshot.data!,
                      title: widget.book.chapters[chapter].title,
                      fontSize: library.fontSize,
                      fontFamily: library.readingFontFamily,
                      horizontalMargin: library.horizontalMargin,
                      verticalMargin: library.verticalMargin,
                      lineHeight: library.lineHeight,
                      initialParagraph: paragraph,
                      initialOffset: characterOffset,
                      comments: comments != null,
                      startAtEnd: pagedStartAtEnd,
                      skipFirstPage: skipFirstPage,
                      onTapTurn: (delta) => unawaited(_turnPage(delta)),
                      loadNextChapter: chapter + 1 < widget.book.chapters.length
                          ? _previewNextChapter
                          : null,
                      onContinueChapter: _advancePaged,
                      onPreviewRows: (rows) {
                        previewRows = rows;
                        _scheduleCounts();
                      },
                      onPreviousChapter: chapter > 0 ? _previousPaged : null,
                      onNextChapter: chapter + 1 < widget.book.chapters.length
                          ? _advancePaged
                          : null,
                      onPosition: (index, offset, rows) {
                        if (settingsOpen) return;
                        final pager = pagedKey.currentState;
                        if (pager?.columns == 2) {
                          skipFirstPage = pager!.firstPage == 1;
                          final entry =
                              library.pagedChapterEntries[_entryKey(chapter)];
                          if (entry != null && entry.isNotEmpty) {
                            entry[0] = skipFirstPage ? 1 : 0;
                          }
                        }
                        paragraph = index;
                        characterOffset = offset;
                        pageRows = rows;
                        _track();
                      },
                      imageBuilder: (url) => BookImage(
                        library: library,
                        book: widget.book,
                        url: url,
                      ),
                      commentBuilder: _commentButton,
                    );
                  }
                  return BoundaryScroll(
                    key: ValueKey('chapter-scroll-$loadGeneration'),
                    axis: Axis.vertical,
                    onPrevious: chapter > 0 ? () => _stepChapter(-1) : null,
                    onNext: chapter + 1 < widget.book.chapters.length
                        ? () => _stepChapter(1)
                        : null,
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: ClampingScrollPhysics(),
                      ),
                      key: viewport,
                      controller: scroll,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: ReadingLayout.singleWidth,
                          ),
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
                                  style: Theme.of(
                                    context,
                                  ).textTheme.headlineSmall,
                                ),
                                const SizedBox(height: 32),
                                for (var i = 0; i < paragraphs.length; i++)
                                  Padding(
                                    key: keys[i],
                                    padding: const EdgeInsets.only(bottom: 18),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
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
                                                    fontFamily: library
                                                        .readingFontFamily,
                                                    height: library.lineHeight,
                                                  ),
                                                ),
                                        ),
                                        if (comments != null &&
                                            paragraphs[i].remoteIndex != null)
                                          _commentButton(paragraphs[i]),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              bottomNavigationBar: SafeArea(
                top: false,
                child: Align(
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: ReadingLayout.canvasWidth(
                        MediaQuery.sizeOf(context).width,
                        paged: library.readingMode == ReadingMode.paged,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          TextButton.icon(
                            onPressed: chapter > 0
                                ? () => _go(chapter - 1, atEnd: true)
                                : null,
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
        return ExcludeReadingTap(
          child: TextButton.icon(
            onPressed: () => setState(
              () => bytes = widget.library.loadImage(widget.book, widget.url),
            ),
            icon: const Icon(Icons.broken_image_outlined),
            label: const Text('插图加载失败，点击重试'),
          ),
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
