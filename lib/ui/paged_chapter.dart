import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/models.dart';
import 'text_pagination.dart';
import 'reading_layout.dart';
import 'boundary_scroll.dart';

class ChapterPreview {
  const ChapterPreview({
    required this.content,
    required this.title,
    required this.hasFollowingChapter,
    required this.commentBuilder,
  });
  final ChapterContent content;
  final String title;
  final bool hasFollowingChapter;
  final Widget Function(Paragraph paragraph) commentBuilder;
}

typedef ChapterContinuation = ({
  int paragraph,
  int offset,
  bool skipFirstPage,
  bool skipChapter,
});

class PagedChapter extends StatefulWidget {
  const PagedChapter({
    super.key,
    required this.content,
    required this.title,
    required this.fontSize,
    required this.initialParagraph,
    required this.initialOffset,
    required this.onPosition,
    required this.imageBuilder,
    required this.commentBuilder,
    required this.comments,
    this.fontFamily,
    this.horizontalMargin = 22,
    this.verticalMargin = 24,
    this.lineHeight = 1.9,
    this.startAtEnd = false,
    this.onPreviousChapter,
    this.onNextChapter,
    this.loadNextChapter,
    this.onContinueChapter,
    this.onPreviewRows,
    this.skipFirstPage = false,
  });
  final ChapterContent content;
  final String title;
  final double fontSize;
  final String? fontFamily;
  final double horizontalMargin, verticalMargin, lineHeight;
  final int initialParagraph, initialOffset;
  final bool comments;
  final bool startAtEnd;
  final VoidCallback? onPreviousChapter, onNextChapter;
  final Future<ChapterPreview> Function()? loadNextChapter;
  final ValueChanged<ChapterContinuation>? onContinueChapter;
  final ValueChanged<Set<int>>? onPreviewRows;
  final bool skipFirstPage;
  final void Function(int paragraph, int offset, Set<int> visibleRows)
  onPosition;
  final Widget Function(String url) imageBuilder;
  final Widget Function(Paragraph paragraph) commentBuilder;
  @override
  State<PagedChapter> createState() => PagedChapterState();
}

class PagedChapterState extends State<PagedChapter> {
  PageController? controller;
  List<List<PageFragment>> pages = [];
  List<List<PageFragment>> previewPages = [];
  ChapterPreview? preview;
  Object? previewError;
  Object? previewSignature;
  double previewHeadingSpace = 0;
  bool previewLoading = false, previewScheduled = false;
  Object? signature;
  int page = 0, revision = 0, columns = 1;
  int firstPage = 0;
  int get spreads => ((pages.length - firstPage) / columns).ceil();
  bool get fillsRight => columns == 2 && (pages.length - firstPage).isOdd;
  bool get hasNext =>
      !(fillsRight &&
          previewPages.length == 1 &&
          preview?.hasFollowingChapter == false) &&
      widget.onNextChapter != null;
  late int anchorParagraph = widget.initialParagraph;
  late int anchorOffset = widget.initialOffset;
  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  void _report({bool preserveAnchor = false}) {
    if (!mounted || pages.isEmpty) return;
    final fragments = pages.skip(page).take(columns).expand((p) => p).toList();
    if (fragments.isNotEmpty && !preserveAnchor) {
      anchorParagraph = fragments.first.paragraph;
      anchorOffset = fragments.first.offset;
    }
    widget.onPosition(anchorParagraph, anchorOffset, {
      for (final fragment in fragments)
        if (widget.content.paragraphs[fragment.paragraph].remoteIndex != null)
          widget.content.paragraphs[fragment.paragraph].remoteIndex!,
    });
    widget.onPreviewRows?.call({
      if (fillsRight && page == pages.length - 1 && previewPages.isNotEmpty)
        for (final fragment in previewPages.first)
          if (preview!.content.paragraphs[fragment.paragraph].remoteIndex !=
              null)
            preview!.content.paragraphs[fragment.paragraph].remoteIndex!,
    });
  }

  Future<void> _loadPreview() async {
    final load = widget.loadNextChapter;
    if (load == null || previewLoading || !mounted) return;
    setState(() {
      previewLoading = true;
      previewError = null;
    });
    try {
      final value = await load();
      if (mounted) setState(() => preview = value);
    } catch (error) {
      if (mounted) setState(() => previewError = error);
    } finally {
      if (mounted) setState(() => previewLoading = false);
    }
  }

  void _continue() {
    final onContinue = widget.onContinueChapter;
    if (fillsRight &&
        preview != null &&
        previewPages.isNotEmpty &&
        onContinue != null) {
      if (previewPages.length > 1) {
        final start = previewPages[1].first;
        onContinue((
          paragraph: start.paragraph,
          offset: start.offset,
          skipFirstPage: true,
          skipChapter: false,
        ));
      } else if (preview!.hasFollowingChapter) {
        onContinue((
          paragraph: 0,
          offset: 0,
          skipFirstPage: false,
          skipChapter: true,
        ));
      }
    } else {
      widget.onNextChapter?.call();
    }
  }

  Future<void> turnPage(int delta) async {
    final target = (page - firstPage) ~/ columns + delta;
    if (controller?.hasClients != true) return;
    if (target < 0) {
      widget.onPreviousChapter?.call();
      return;
    }
    if (target >= spreads) {
      if (hasNext) _continue();
      return;
    }
    await controller!.animateToPage(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      columns = ReadingLayout.columns(constraints.maxWidth);
      final canvasWidth = ReadingLayout.canvasWidth(
        constraints.maxWidth,
        paged: true,
      );
      final gutter = columns == 2 ? ReadingLayout.gutter : 0.0;
      final width =
          ((canvasWidth - widget.horizontalMargin * 2 - gutter) / columns)
              .clamp(1.0, double.infinity);
      final style = Theme.of(context).textTheme.bodyLarge!.copyWith(
        fontSize: widget.fontSize,
        fontFamily: widget.fontFamily,
        height: widget.lineHeight,
      );
      final headingStyle = Theme.of(context).textTheme.headlineSmall!;
      final scaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      final locale = Localizations.maybeLocaleOf(context);
      final sample = TextPainter(
        text: TextSpan(text: '国', style: style),
        textScaler: scaler,
        textDirection: direction,
        locale: locale,
      )..layout(maxWidth: width);
      final minimum = sample.height + 18;
      sample.dispose();
      final verticalMargin = widget.verticalMargin.clamp(
        0.0,
        ((constraints.maxHeight - 48 - minimum) / 2).clamp(
          0.0,
          widget.verticalMargin,
        ),
      );
      final height = (constraints.maxHeight - 48 - verticalMargin * 2).clamp(
        1.0,
        double.infinity,
      );
      final heading = TextPainter(
        text: TextSpan(text: widget.title, style: headingStyle),
        textScaler: scaler,
        textDirection: direction,
        maxLines: 2,
        ellipsis: '…',
        locale: locale,
      )..layout(maxWidth: width);
      final headingSpace = (heading.height + 24).clamp(
        0.0,
        (height - minimum).clamp(0.0, double.infinity),
      );
      heading.dispose();
      final nextSignature = (
        widget.content,
        columns,
        width,
        height,
        style,
        scaler,
        direction,
        locale,
        headingSpace,
      );
      if (signature != nextSignature) {
        final enterAtEnd = signature == null && widget.startAtEnd;
        signature = nextSignature;
        pages = TextPagination.paginate(
          widget.content.paragraphs,
          width: width,
          height: height,
          style: style,
          scaler: scaler,
          direction: direction,
          locale: locale,
          comments: widget.comments,
          headingSpace: headingSpace,
          anchorParagraph: enterAtEnd ? null : anchorParagraph,
          anchorOffset: anchorOffset,
        );
        page = 0;
        for (var i = 0; i < pages.length; i++) {
          if (pages[i].any(
            (fragment) =>
                fragment.paragraph < anchorParagraph ||
                fragment.paragraph == anchorParagraph &&
                    fragment.offset <= anchorOffset,
          )) {
            page = i;
          }
        }
        if (enterAtEnd) page = pages.length - 1;
        firstPage =
            widget.skipFirstPage && columns == 2 && pages.length > 1 && page > 0
            ? 1
            : 0;
        page =
            firstPage +
            ((page - firstPage).clamp(0, pages.length) ~/ columns) * columns;
        final old = controller;
        controller = PageController(initialPage: (page - firstPage) ~/ columns);
        final generation = ++revision;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          old?.dispose();
          if (mounted && generation == revision) {
            _report(preserveAnchor: !enterAtEnd);
          }
        });
      }
      final next = preview;
      if (next != null && previewSignature != (nextSignature, next)) {
        previewSignature = (nextSignature, next);
        final nextHeading = TextPainter(
          text: TextSpan(text: next.title, style: headingStyle),
          textScaler: scaler,
          textDirection: direction,
          maxLines: 2,
          ellipsis: '…',
          locale: locale,
        )..layout(maxWidth: width);
        final nextHeadingSpace = (nextHeading.height + 24).clamp(
          0.0,
          (height - minimum).clamp(0.0, double.infinity),
        );
        previewHeadingSpace = nextHeadingSpace;
        nextHeading.dispose();
        previewPages = TextPagination.paginate(
          next.content.paragraphs,
          width: width,
          height: height,
          style: style,
          scaler: scaler,
          direction: direction,
          locale: locale,
          comments: widget.comments,
          headingSpace: nextHeadingSpace,
        );
        // Preview rows belong to another chapter; refresh their counts without
        // moving the saved reading position away from the left-hand page.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _report(preserveAnchor: true);
        });
      }
      if (fillsRight &&
          page == pages.length - 1 &&
          widget.loadNextChapter != null &&
          preview == null &&
          previewError == null &&
          !previewLoading &&
          !previewScheduled) {
        previewScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          previewScheduled = false;
          if (mounted) _loadPreview();
        });
      }
      final pageRevision = revision;
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.pageUp): () => turnPage(-1),
          const SingleActivator(LogicalKeyboardKey.pageDown): () => turnPage(1),
        },
        child: Focus(
          autofocus: true,
          child: Column(
            children: [
              Expanded(
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.trackpad,
                      PointerDeviceKind.stylus,
                    },
                  ),
                  child: BoundaryScroll(
                    axis: Axis.horizontal,
                    onPrevious: widget.onPreviousChapter != null
                        ? () => turnPage(-1)
                        : null,
                    onNext: hasNext ? () => turnPage(1) : null,
                    child: PageView.builder(
                      physics: const PageScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(
                          parent: ClampingScrollPhysics(),
                        ),
                      ),
                      key: ValueKey(revision),
                      controller: controller,
                      itemCount: spreads,
                      onPageChanged: (value) {
                        if (pageRevision != revision ||
                            value < 0 ||
                            value >= spreads) {
                          return;
                        }
                        setState(() => page = firstPage + value * columns);
                        _report();
                      },
                      itemBuilder: (context, spread) => Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: canvasWidth,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              widget.horizontalMargin,
                              verticalMargin,
                              widget.horizontalMargin,
                              verticalMargin,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (
                                  var column = 0;
                                  column < columns;
                                  column++
                                ) ...[
                                  if (column > 0)
                                    SizedBox(
                                      width: gutter,
                                      child: Center(
                                        child: VerticalDivider(
                                          width: 1,
                                          color: Theme.of(context).dividerColor
                                              .withValues(alpha: 0.25),
                                        ),
                                      ),
                                    ),
                                  Expanded(
                                    child:
                                        firstPage + spread * columns + column <
                                            pages.length
                                        ? _page(
                                            context,
                                            firstPage +
                                                spread * columns +
                                                column,
                                            style,
                                            headingStyle,
                                            scaler,
                                            headingSpace,
                                          )
                                        : _previewPage(
                                            context,
                                            style,
                                            headingStyle,
                                            scaler,
                                          ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 48,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed:
                          page > firstPage || widget.onPreviousChapter != null
                          ? () => turnPage(-1)
                          : null,
                      child: const Text('上一页'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        columns == 2 && page + 1 < pages.length
                            ? '第 ${page + 1}–${page + 2} / ${pages.length} 页'
                            : '第 ${page + 1} / ${pages.length} 页${fillsRight && preview != null ? ' · 下一章第 1 页' : ''}',
                      ),
                    ),
                    TextButton(
                      onPressed: page + columns < pages.length || hasNext
                          ? () => turnPage(1)
                          : null,
                      child: const Text('下一页'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _page(
    BuildContext context,
    int index,
    TextStyle style,
    TextStyle headingStyle,
    TextScaler scaler,
    double headingSpace, {
    ChapterPreview? next,
    List<PageFragment>? fragments,
  }) => SingleChildScrollView(
    key: ValueKey('${next == null ? 'reading' : 'preview'}-page-$index'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (index == 0)
          SizedBox(
            height: headingSpace,
            child: Text(
              next?.title ?? widget.title,
              style: headingStyle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        for (final fragment in fragments ?? pages[index])
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: SizedBox(
              height: fragment.height,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: fragment.image
                        ? widget.imageBuilder(
                            (next?.content ?? widget.content)
                                .paragraphs[fragment.paragraph]
                                .image!,
                          )
                        : SelectableText(
                            fragment.text,
                            style: style,
                            textScaler: scaler,
                          ),
                  ),
                  if (widget.comments &&
                      (next?.content ?? widget.content)
                              .paragraphs[fragment.paragraph]
                              .remoteIndex !=
                          null)
                    SizedBox(
                      width: 56,
                      child: (next?.commentBuilder ?? widget.commentBuilder)(
                        (next?.content ?? widget.content).paragraphs[fragment
                            .paragraph],
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    ),
  );

  Widget _previewPage(
    BuildContext context,
    TextStyle style,
    TextStyle headingStyle,
    TextScaler scaler,
  ) {
    final next = preview;
    if (next != null && previewPages.isNotEmpty) {
      return _page(
        context,
        0,
        style,
        headingStyle,
        scaler,
        previewHeadingSpace,
        next: next,
        fragments: previewPages.first,
      );
    }
    if (widget.loadNextChapter == null) return const SizedBox.shrink();
    if (previewError == null && (!previewLoading || page != pages.length - 1)) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: previewError == null
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在加载下一章'),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('下一章加载失败：$previewError'),
                  TextButton(
                    onPressed: _loadPreview,
                    child: const Text('重试下一章'),
                  ),
                ],
              ),
      ),
    );
  }
}
