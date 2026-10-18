import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../data/library.dart';
import '../domain/models.dart';
import 'chapter_page_layout.dart';

class ReaderPagePosition {
  const ReaderPagePosition({
    required this.layout,
    required this.chapter,
    required this.paragraph,
    required this.offset,
    this.localPage,
    this.localPages,
  });
  final ChapterPageLayout layout;
  final int chapter, paragraph, offset;
  final int? localPage, localPages;
}

class BookPageProgress extends StatefulWidget {
  const BookPageProgress({
    super.key,
    required this.library,
    required this.book,
    required this.position,
    required this.contents,
    required this.onSeek,
  });
  final Library library;
  final Book book;
  final ValueListenable<ReaderPagePosition?> position;
  final Map<int, ChapterContent> contents;
  final void Function(int chapter, int paragraph, int offset) onSeek;
  @override
  State<BookPageProgress> createState() => _BookPageProgressState();
}

class _BookPageProgressState extends State<BookPageProgress> {
  final stats = <int, ({int words, List<(int, int)> starts})>{};
  Object? signature;
  int generation = 0;
  Book? metadata;
  bool metadataRequested = false;
  double? dragPage;
  List<int>? dragCounts;
  bool seeking = false;

  Future<void> _seek(double value, List<int> counts) async {
    final position = widget.position.value;
    if (position == null || seeking) return;
    final token = generation;
    var page = value.round() - 1;
    var chapter = 0;
    while (chapter < counts.length - 1 && page >= counts[chapter]) {
      page -= counts[chapter++];
    }
    setState(() {
      seeking = true;
      dragPage = null;
      dragCounts = null;
    });
    try {
      var starts = stats[chapter]?.starts;
      if (starts == null) {
        // Only the chapter explicitly selected by the reader is fetched.
        final content = await widget.library.read(
          widget.book,
          widget.book.chapters[chapter],
        );
        if (!mounted ||
            token != generation ||
            widget.position.value != position) {
          return;
        }
        widget.contents[chapter] = content;
        _index(chapter, content, position.layout);
        starts = stats[chapter]!.starts;
      }
      if (!mounted ||
          token != generation ||
          widget.position.value != position ||
          starts.isEmpty) {
        return;
      }
      if (counts[chapter] != starts.length) {
        page = counts[chapter] <= 1
            ? 0
            : (page / (counts[chapter] - 1) * (starts.length - 1)).round();
      }
      final (paragraph, offset) = starts[page.clamp(0, starts.length - 1)];
      widget.onSeek(chapter, paragraph, offset);
    } catch (error) {
      if (mounted && token == generation) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('跳转失败，请重试：$error')));
      }
    } finally {
      if (mounted) setState(() => seeking = false);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.position.addListener(_changed);
    _changed();
  }

  void _index(int index, ChapterContent content, ChapterPageLayout layout) {
    if (stats.containsKey(index)) return;
    final chapter = widget.book.chapters[index];
    final pages = layout.paginate(
      content,
      chapter.title,
      titleComments:
          widget.library
              .commentsFor(widget.book)
              ?.chapterTitleParagraph(chapter) !=
          null,
    );
    stats[index] = (
      words: content.paragraphs.fold(0, (sum, p) => sum + p.text.runes.length),
      starts: [
        for (final page in pages)
          page.isEmpty ? (0, 0) : (page.first.paragraph, page.first.offset),
      ],
    );
  }

  void _changed() {
    final position = widget.position.value;
    if (position == null) return;
    if (signature != position.layout.signature) {
      signature = position.layout.signature;
      stats.clear();
      dragPage = null;
      dragCounts = null;
      final token = ++generation;
      unawaited(_scan(position.layout, token));
    }
    for (final entry in widget.contents.entries) {
      _index(entry.key, entry.value, position.layout);
    }
    if (mounted) setState(() {});
  }

  Future<void> _scan(ChapterPageLayout layout, int token) async {
    // Reading the local cache must never trigger downloads of the whole book.
    for (var i = 0; i < widget.book.chapters.length; i++) {
      if (!mounted || token != generation) return;
      if (!stats.containsKey(i)) {
        try {
          final content =
              widget.contents[i] ??
              await widget.library.cached(widget.book, widget.book.chapters[i]);
          if (!mounted || token != generation) return;
          if (content != null) _index(i, content, layout);
        } catch (_) {
          // Corrupt or inaccessible local chapters remain estimates.
        }
      }
      if ((i + 1) % 8 == 0) {
        if (mounted) setState(() {});
        await WidgetsBinding.instance.endOfFrame;
      }
    }
    if (!mounted || token != generation) return;
    setState(() {});
    if (stats.length < widget.book.chapters.length &&
        widget.book.wordCount == null &&
        !metadataRequested) {
      metadataRequested = true;
      final source = widget.library.sourceFor(widget.book);
      if (source == null) return;
      try {
        final book = await source.getBook(widget.book.id);
        if (mounted && book.key == widget.book.key) {
          setState(() => metadata = book);
        }
      } catch (_) {
        // Metadata failure does not interrupt reading or remove cached counts.
      }
    }
  }

  @override
  void dispose() {
    generation++;
    widget.position.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final position = widget.position.value;
    if (position == null || stats.isEmpty) {
      return const Column(
        children: [
          Expanded(child: Slider(value: 0, onChanged: null)),
          Text('—/—'),
        ],
      );
    }
    final chapters = widget.book.chapters;
    final extra = {
      for (final c in metadata?.chapters ?? <Chapter>[]) c.id: c.wordCount,
    };
    final words = <int?>[
      for (var i = 0; i < chapters.length; i++)
        stats[i]?.words ?? chapters[i].wordCount ?? extra[chapters[i].id],
    ];
    var measuredWords = 0, measuredPages = 0;
    for (final entry in stats.entries) {
      measuredWords += entry.value.words;
      measuredPages +=
          entry.key == position.chapter && position.localPages != null
          ? position.localPages!
          : entry.value.starts.length;
    }
    final perPage = math.max(1.0, measuredWords / math.max(1, measuredPages));
    final knownWords = words.whereType<int>().fold(0, (a, b) => a + b);
    final unknown = words.where((w) => w == null).length;
    final totalWords = widget.book.wordCount ?? metadata?.wordCount;
    final average = unknown > 0 && totalWords != null
        ? math.max(0.0, (totalWords - knownWords) / unknown)
        : knownWords / math.max(1, words.length - unknown);
    final counts =
        dragCounts ??
        <int>[
          for (var i = 0; i < chapters.length; i++)
            if (i == position.chapter && position.localPages != null)
              position.localPages!
            else if (stats[i] != null)
              stats[i]!.starts.length
            else
              math.max(1, ((words[i] ?? average) / perPage).ceil()),
        ];
    var local = position.localPage;
    if (local == null) {
      local = 1;
      final starts = stats[position.chapter]?.starts ?? [];
      for (var i = 0; i < starts.length; i++) {
        final (paragraph, offset) = starts[i];
        if (paragraph < position.paragraph ||
            paragraph == position.paragraph && offset <= position.offset) {
          local = i + 1;
        }
      }
    }
    final total = counts.fold(0, (a, b) => a + b);
    final current =
        (counts.take(position.chapter).fold(0, (a, b) => a + b) + (local ?? 1))
            .clamp(1, total);
    final estimated = stats.length != chapters.length;
    final displayed = (dragPage?.round() ?? current).clamp(1, total);
    return Column(
      children: [
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              key: const ValueKey('book-progress-slider'),
              min: 1,
              max: total > 1 ? total.toDouble() : 2,
              value: displayed.toDouble(),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              semanticFormatterCallback: (value) =>
                  '第 ${value.round()} 页，共 $total 页',
              onChangeStart: seeking || total <= 1
                  ? null
                  : (_) => dragCounts = List.of(counts),
              onChanged: seeking || total <= 1
                  ? null
                  : (value) => setState(() => dragPage = value),
              onChangeEnd: seeking || total <= 1
                  ? null
                  : (value) => unawaited(_seek(value, dragCounts ?? counts)),
            ),
          ),
        ),
        SizedBox(
          height: 20,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '$displayed/${estimated ? '约' : ''}$total',
              key: const ValueKey('book-page-progress'),
              textAlign: TextAlign.center,
              semanticsLabel:
                  '${estimated ? '估算全书页码' : '全书页码'}，第 $displayed 页，共 $total 页',
            ),
          ),
        ),
      ],
    );
  }
}
