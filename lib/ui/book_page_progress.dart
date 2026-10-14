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
  });
  final Library library;
  final Book book;
  final ValueListenable<ReaderPagePosition?> position;
  final Map<int, ChapterContent> contents;
  @override
  State<BookPageProgress> createState() => _BookPageProgressState();
}

class _BookPageProgressState extends State<BookPageProgress> {
  final stats = <int, ({int words, List<(int, int)> starts})>{};
  Object? signature;
  int generation = 0;
  Book? metadata;
  bool metadataRequested = false;

  @override
  void initState() {
    super.initState();
    widget.position.addListener(_changed);
    _changed();
  }

  void _index(int index, ChapterContent content, ChapterPageLayout layout) {
    if (stats.containsKey(index)) return;
    final pages = layout.paginate(content, widget.book.chapters[index].title);
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
    if (position == null || stats.isEmpty) return const Text('—/—');
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
    final counts = <int>[
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
    return Text(
      '$current/${estimated ? '约' : ''}$total',
      key: const ValueKey('book-page-progress'),
      textAlign: TextAlign.center,
      semanticsLabel:
          '${estimated ? '估算全书页码' : '全书页码'}，第 $current 页，共 $total 页',
    );
  }
}
