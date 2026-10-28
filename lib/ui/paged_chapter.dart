import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/models.dart';
import '../domain/reading_preferences.dart';
import 'text_pagination.dart';
import 'boundary_scroll.dart';
import 'reading_tap_zones.dart';
import 'chapter_page_layout.dart';
import 'reading_paragraph.dart';
import 'page_turn_effect.dart';
import 'reading_heading.dart';

class ChapterPreview {
  const ChapterPreview({
    required this.content,
    required this.title,
    required this.hasFollowingChapter,
    required this.commentBuilder,
    this.titleParagraph,
  });
  final ChapterContent content;
  final String title;
  final bool hasFollowingChapter;
  final Widget Function(Paragraph paragraph) commentBuilder;
  final Paragraph? titleParagraph;
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
    this.titleParagraph,
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
    this.nextChapterErrorBuilder,
    this.skipFirstPage = false,
    this.onTapTurn,
    this.onCenterTap,
    this.showPageIndicator = true,
    this.commentPlacement = ParagraphCommentPlacement.right,
    this.pageTurnAnimation = PageTurnAnimation.slide,
    this.onShareQuote,
  });
  final ChapterContent content;
  final String title;
  final double fontSize;
  final String? fontFamily;
  final double horizontalMargin, verticalMargin, lineHeight;
  final int initialParagraph, initialOffset;
  final bool comments;
  final Paragraph? titleParagraph;
  final ParagraphCommentPlacement commentPlacement;
  final PageTurnAnimation pageTurnAnimation;
  final ValueChanged<String>? onShareQuote;
  final bool startAtEnd;
  final VoidCallback? onPreviousChapter, onNextChapter;
  final Future<ChapterPreview> Function()? loadNextChapter;
  final ValueChanged<ChapterContinuation>? onContinueChapter;
  final ValueChanged<Set<int>>? onPreviewRows;
  final Widget Function(Object error, VoidCallback retry)?
  nextChapterErrorBuilder;
  final bool skipFirstPage;
  final ValueChanged<int>? onTapTurn;
  final VoidCallback? onCenterTap;
  final bool showPageIndicator;
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
  PageTurnAnimation get animation => MediaQuery.disableAnimationsOf(context)
      ? PageTurnAnimation.none
      : widget.pageTurnAnimation;
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
      if (widget.comments &&
          page == 0 &&
          widget.titleParagraph?.remoteIndex != null)
        widget.titleParagraph!.remoteIndex!,
      for (final fragment in fragments)
        if (widget.content.paragraphs[fragment.paragraph].remoteIndex != null)
          widget.content.paragraphs[fragment.paragraph].remoteIndex!,
    });
    widget.onPreviewRows?.call({
      if (widget.comments &&
          fillsRight &&
          page == pages.length - 1 &&
          previewPages.isNotEmpty &&
          preview?.titleParagraph?.remoteIndex != null)
        preview!.titleParagraph!.remoteIndex!,
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
    if (animation == PageTurnAnimation.none) {
      controller!.jumpToPage(target);
      return;
    }
    await controller!.animateToPage(
      target,
      duration: Duration(
        milliseconds: animation == PageTurnAnimation.simulation ? 360 : 180,
      ),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final layout = ChapterPageLayout(
        context,
        constraints.biggest,
        fontSize: widget.fontSize,
        fontFamily: widget.fontFamily,
        horizontalMargin: widget.horizontalMargin,
        verticalMargin: widget.verticalMargin,
        lineHeight: widget.lineHeight,
        comments: widget.comments,
        commentPlacement: widget.commentPlacement,
        footerHeight: widget.showPageIndicator ? 48 : 0,
      );
      columns = layout.columns;
      final canvasWidth = layout.canvasWidth;
      final width = layout.width, height = layout.height;
      final style = layout.style, headingStyle = layout.headingStyle;
      final scaler = layout.scaler, direction = layout.direction;
      final locale = layout.locale;
      final verticalMargin = layout.margin;
      final headingSpace = layout.headingSpace(
        widget.title,
        titleComments: widget.titleParagraph != null,
      );
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
        widget.comments,
        widget.titleParagraph?.remoteIndex,
        widget.commentPlacement,
        widget.horizontalMargin,
        layout.textLayout.signature,
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
          commentPlacement: widget.commentPlacement,
          commentRightInset: widget.horizontalMargin,
          headingSpace: headingSpace,
          anchorParagraph: enterAtEnd ? null : anchorParagraph,
          anchorOffset: anchorOffset,
          textLayout: layout.textLayout,
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
        final nextHeadingSpace = layout.headingSpace(
          next.title,
          titleComments: next.titleParagraph != null,
        );
        previewHeadingSpace = nextHeadingSpace;
        previewPages = TextPagination.paginate(
          next.content.paragraphs,
          width: width,
          height: height,
          style: style,
          scaler: scaler,
          direction: direction,
          locale: locale,
          comments: widget.comments,
          commentPlacement: widget.commentPlacement,
          commentRightInset: widget.horizontalMargin,
          headingSpace: nextHeadingSpace,
          textLayout: layout.textLayout,
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
          child: ReadingTapZones(
            revision: (signature, page, firstPage),
            onTurn: widget.onTapTurn ?? (delta) => turnPage(delta),
            onCenterTap: widget.onCenterTap,
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
                        itemBuilder: (context, spread) => _pageEffect(
                          spread,
                          Align(
                            alignment: Alignment.topCenter,
                            child: SizedBox(
                              width: canvasWidth,
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  vertical: verticalMargin,
                                ),
                                child: Stack(
                                  children: [
                                    if (columns == 2)
                                      Positioned.fill(
                                        child: Center(
                                          child: VerticalDivider(
                                            width: 1,
                                            color: Theme.of(context)
                                                .dividerColor
                                                .withValues(alpha: 0.25),
                                          ),
                                        ),
                                      ),
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        for (
                                          var column = 0;
                                          column < columns;
                                          column++
                                        ) ...[
                                          if (column > 0)
                                            SizedBox(width: layout.gutter),
                                          Expanded(
                                            child:
                                                firstPage +
                                                        spread * columns +
                                                        column <
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
                if (widget.showPageIndicator)
                  SizedBox(
                    height: 48,
                    child: Center(
                      child: Text(
                        columns == 2 && page + 1 < pages.length
                            ? '第 ${page + 1}–${page + 2} / ${pages.length} 页'
                            : '第 ${page + 1} / ${pages.length} 页${fillsRight && preview != null ? ' · 下一章第 1 页' : ''}',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _pageEffect(int spread, Widget child) {
    if (animation == PageTurnAnimation.slide) return child;
    final pageController = controller!;
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: pageController,
        child: child,
        builder: (context, child) {
          final position =
              pageController.hasClients &&
                  pageController.position.hasContentDimensions
              ? pageController.page ?? pageController.initialPage.toDouble()
              : pageController.initialPage.toDouble();
          final relative = spread - position;
          final rtl = Directionality.of(context) == TextDirection.rtl;
          // Cancel the viewport translation: the sheet stays in place while
          // the fold reveals its neighbour. Paging, gestures and boundaries
          // still use the same PageController as the sliding mode.
          return Transform.translate(
            offset: Offset(
              -relative * constraints.maxWidth * (rtl ? -1 : 1),
              0,
            ),
            child: PageTurnEffect(
              position: relative,
              animation: animation,
              paperColor: Theme.of(context).scaffoldBackgroundColor,
              reverse: rtl,
              child: child!,
            ),
          );
        },
      ),
    );
  }

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
    padding: EdgeInsets.only(left: widget.horizontalMargin),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (index == 0)
          SizedBox(
            height: headingSpace,
            child: ReadingHeading(
              text: next?.title ?? widget.title,
              style: headingStyle,
              maxLines: 2,
              rightInset: widget.horizontalMargin,
              placement: widget.commentPlacement,
              comment:
                  widget.comments &&
                      (next == null
                              ? widget.titleParagraph
                              : next.titleParagraph) !=
                          null
                  ? (next?.commentBuilder ?? widget.commentBuilder)(
                      (next == null
                          ? widget.titleParagraph
                          : next.titleParagraph)!,
                    )
                  : null,
            ),
          ),
        for (final fragment in fragments ?? pages[index])
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: SizedBox(
              height: fragment.height,
              child: ReadingParagraph(
                text: fragment.text,
                onShareQuote: widget.onShareQuote,
                style: style,
                textScaler: scaler,
                rightInset: widget.horizontalMargin,
                placement: widget.commentPlacement,
                image: fragment.image
                    ? SizedBox(
                        height: fragment.height,
                        child: widget.imageBuilder(
                          (next?.content ?? widget.content)
                              .paragraphs[fragment.paragraph]
                              .image!,
                        ),
                      )
                    : null,
                comment:
                    widget.comments &&
                        (widget.commentPlacement ==
                                ParagraphCommentPlacement.right ||
                            fragment.endsParagraph) &&
                        (next?.content ?? widget.content)
                                .paragraphs[fragment.paragraph]
                                .remoteIndex !=
                            null
                    ? (next?.commentBuilder ?? widget.commentBuilder)(
                        (next?.content ?? widget.content).paragraphs[fragment
                            .paragraph],
                      )
                    : null,
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
            : ExcludeReadingTap(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('下一章加载失败：$previewError'),
                    if (widget.nextChapterErrorBuilder case final builder?)
                      builder(previewError!, _loadPreview),
                    TextButton(
                      onPressed: _loadPreview,
                      child: const Text('重试下一章'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
