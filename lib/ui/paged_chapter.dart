import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/models.dart';
import 'text_pagination.dart';

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
  });
  final ChapterContent content;
  final String title;
  final double fontSize;
  final int initialParagraph, initialOffset;
  final bool comments;
  final void Function(int paragraph, int offset, Set<int> visibleRows)
  onPosition;
  final Widget Function(String url) imageBuilder;
  final Widget Function(Paragraph paragraph) commentBuilder;
  @override
  State<PagedChapter> createState() => _PagedChapterState();
}

class _PagedChapterState extends State<PagedChapter> {
  PageController? controller;
  List<List<PageFragment>> pages = [];
  Object? signature;
  int page = 0, revision = 0;
  late int anchorParagraph = widget.initialParagraph;
  late int anchorOffset = widget.initialOffset;
  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  void _report() {
    if (!mounted || pages.isEmpty) return;
    final fragments = pages[page];
    if (fragments.isNotEmpty) {
      anchorParagraph = fragments.first.paragraph;
      anchorOffset = fragments.first.offset;
    }
    widget.onPosition(anchorParagraph, anchorOffset, {
      for (final fragment in fragments)
        if (widget.content.paragraphs[fragment.paragraph].remoteIndex != null)
          widget.content.paragraphs[fragment.paragraph].remoteIndex!,
    });
  }

  void _turn(int delta) {
    final target = page + delta;
    if (target < 0 || target >= pages.length || controller?.hasClients != true)
      return;
    controller!.animateToPage(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = (constraints.maxWidth.clamp(1.0, 820.0) - 44).clamp(
        1.0,
        double.infinity,
      );
      final height = (constraints.maxHeight - 88).clamp(60.0, double.infinity);
      final style = Theme.of(
        context,
      ).textTheme.bodyLarge!.copyWith(fontSize: widget.fontSize, height: 1.9);
      final headingStyle = Theme.of(context).textTheme.headlineSmall!;
      final scaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      final locale = Localizations.maybeLocaleOf(context);
      final heading = TextPainter(
        text: TextSpan(text: widget.title, style: headingStyle),
        textScaler: scaler,
        textDirection: direction,
        maxLines: 2,
        ellipsis: '…',
        locale: locale,
      )..layout(maxWidth: width);
      final headingSpace = (heading.height + 24).clamp(0.0, height - 40);
      heading.dispose();
      final nextSignature = (
        widget.content,
        width,
        height,
        style,
        scaler,
        direction,
        locale,
        headingSpace,
      );
      if (signature != nextSignature) {
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
        final old = controller;
        controller = PageController(initialPage: page);
        final generation = ++revision;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          old?.dispose();
          if (mounted && generation == revision) _report();
        });
      }
      final pageRevision = revision;
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.pageUp): () => _turn(-1),
          const SingleActivator(LogicalKeyboardKey.pageDown): () => _turn(1),
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
                  child: PageView.builder(
                    key: ValueKey(revision),
                    controller: controller,
                    itemCount: pages.length,
                    onPageChanged: (value) {
                      if (pageRevision != revision ||
                          value < 0 ||
                          value >= pages.length)
                        return;
                      setState(() => page = value);
                      _report();
                    },
                    itemBuilder: (context, index) => Center(
                      child: SizedBox(
                        width: width,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (index == 0)
                                SizedBox(
                                  height: headingSpace,
                                  child: Text(
                                    widget.title,
                                    style: headingStyle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              for (final fragment in pages[index])
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 18),
                                  child: SizedBox(
                                    height: fragment.height,
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: fragment.image
                                              ? widget.imageBuilder(
                                                  widget
                                                      .content
                                                      .paragraphs[fragment
                                                          .paragraph]
                                                      .image!,
                                                )
                                              : SelectableText(
                                                  fragment.text,
                                                  style: style,
                                                  textScaler: scaler,
                                                ),
                                        ),
                                        if (widget.comments &&
                                            widget
                                                    .content
                                                    .paragraphs[fragment
                                                        .paragraph]
                                                    .remoteIndex !=
                                                null)
                                          SizedBox(
                                            width: 56,
                                            child: widget.commentBuilder(
                                              widget.content.paragraphs[fragment
                                                  .paragraph],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
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
                      onPressed: page > 0 ? () => _turn(-1) : null,
                      child: const Text('上一页'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text('第 ${page + 1} / ${pages.length} 页'),
                    ),
                    TextButton(
                      onPressed: page + 1 < pages.length
                          ? () => _turn(1)
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
}
