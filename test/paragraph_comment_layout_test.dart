import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/domain/reading_preferences.dart';
import 'package:unr/ui/paged_chapter.dart';
import 'package:unr/ui/paragraph_comment_button.dart';
import 'package:unr/ui/reading_paragraph.dart';
import 'package:unr/ui/reading_tap_zones.dart';
import 'package:unr/ui/text_pagination.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    required String text,
    required ParagraphCommentPlacement placement,
    double width = 360,
    double margin = 22,
    double scale = 1,
    int? count,
    bool failed = false,
    VoidCallback? onPressed,
    ValueChanged<int>? onTurn,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: ReadingTapZones(
              onTurn: onTurn ?? (_) {},
              child: SingleChildScrollView(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: Padding(
                      padding: EdgeInsets.only(left: margin),
                      child: ReadingParagraph(
                        text: text,
                        style: const TextStyle(fontSize: 20, height: 1.9),
                        rightInset: margin,
                        placement: placement,
                        comment: ParagraphCommentButton(
                          count: count,
                          failed: failed,
                          onPressed: onPressed ?? () {},
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
    await tester.pump();
  }

  for (final margin in [8.0, 22.0, 64.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('右侧气泡靠边、对齐末行，计数更新不改变正文（边距$margin，缩放$scale）', (tester) async {
        final text = '　　${'正文保持整齐。' * 8}';
        await mount(
          tester,
          text: text,
          placement: ParagraphCommentPlacement.right,
          margin: margin,
          scale: scale,
        );
        final originalText = tester.getRect(find.byType(SelectableText));
        final originalParagraph = tester.getRect(find.byType(ReadingParagraph));
        final originalBadge = tester.getRect(
          find.byType(ParagraphCommentButton),
        );
        expect(originalBadge.right, closeTo(358, .01));
        expect(originalBadge.width, 28);
        expect(originalText.right, lessThanOrEqualTo(originalBadge.left - 4));
        expect(originalBadge.top, greaterThan(originalText.top + 38));
        expect(
          originalBadge.bottom,
          lessThanOrEqualTo(originalParagraph.bottom),
        );
        for (final count in [0, 7, 999, 10000, null]) {
          await mount(
            tester,
            text: text,
            placement: ParagraphCommentPlacement.right,
            margin: margin,
            scale: scale,
            count: count,
            failed: count == null,
          );
          expect(tester.getRect(find.byType(SelectableText)), originalText);
          expect(
            tester.getRect(find.byType(ReadingParagraph)),
            originalParagraph,
          );
          expect(
            tester.getRect(find.byType(ParagraphCommentButton)),
            originalBadge,
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('段尾气泡紧跟末行，满行时另起一行且正文不重排', (tester) async {
    for (final text in ['　　短段。', '字' * 15, '字' * 15 + '\n结尾']) {
      await mount(
        tester,
        text: text,
        width: 344,
        placement: ParagraphCommentPlacement.paragraphEnd,
        count: 80,
      );
      final body = tester.getRect(find.byType(SelectableText));
      final badge = tester.getRect(find.byType(ParagraphCommentButton));
      // The Flutter test font uses 20px-wide glyphs, with 300px for text here.
      if (text == '字' * 15) {
        expect(body.height, closeTo(38, .01));
        expect(badge.top, closeTo(body.bottom, .01));
        expect(badge.left, body.left);
      } else {
        final lastLineLength = text.split('\n').last.length;
        expect(badge.left, closeTo(body.left + lastLineLength * 20 + 4, .01));
        expect(badge.bottom, lessThanOrEqualTo(body.bottom));
      }
      expect(tester.takeException(), isNull);
    }
  });

  for (final placement in ParagraphCommentPlacement.values) {
    testWidgets('小气泡可点击，计数合并且不触发翻页（${placement.name}）', (tester) async {
      var opened = 0, turns = 0;
      await mount(
        tester,
        text: '　　正文',
        placement: placement,
        count: 10000,
        onPressed: () => opened++,
        onTurn: (_) => turns++,
      );
      expect(find.text('999+'), findsOneWidget);
      final label = tester.renderObject<RenderParagraph>(find.text('999+'));
      final boxes = label.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 4),
      );
      expect(boxes.map((box) => box.top).toSet(), hasLength(1));
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
      await tester.tap(find.byTooltip('阅读本段段评'));
      await tester.pump(const Duration(milliseconds: 700));
      expect(opened, 1);
      expect(turns, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('分页测量与实际段落一致，段尾模式只在最终片段显示入口（${placement.name}）', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final text = '连续段落😀中文。' * 100;
      final key = GlobalKey<PagedChapterState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PagedChapter(
              key: key,
              content: ChapterContent([Paragraph(text, remoteIndex: 1)]),
              title: '长章节名称' * 10,
              fontSize: 20,
              horizontalMargin: 8,
              initialParagraph: 0,
              initialOffset: 0,
              comments: true,
              commentPlacement: placement,
              onPosition: (_, _, _) {},
              imageBuilder: (_) => const SizedBox.shrink(),
              commentBuilder: (_) =>
                  ParagraphCommentButton(count: 80, onPressed: () {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final state = key.currentState!;
      expect(state.pages.length, greaterThan(2));
      expect(state.pages.expand((p) => p).map((f) => f.text).join(), '　　$text');
      expect(
        find.byType(ParagraphCommentButton).hitTestable(),
        placement == ParagraphCommentPlacement.right
            ? findsOneWidget
            : findsNothing,
      );
      for (var page = 0; page < state.pages.length; page++) {
        state.controller!.jumpToPage(page);
        await tester.pumpAndSettle();
        final fragment = state.pages[page].single;
        final paragraph = find.byType(ReadingParagraph).hitTestable().first;
        final rendered = tester.getSize(paragraph).height;
        expect(rendered, closeTo(fragment.height, .01));
        final body = find.descendant(
          of: paragraph,
          matching: find.byType(SelectableText),
        );
        expect(tester.getSize(body).height, lessThanOrEqualTo(rendered + .01));
      }
      expect(find.byType(ParagraphCommentButton).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('大字与低行距下分页不裁切气泡或正文', (tester) async {
    for (final placement in ParagraphCommentPlacement.values) {
      for (final style in [
        const TextStyle(fontSize: 14, height: 1.2),
        const TextStyle(fontSize: 32, height: 2.6),
      ]) {
        const scaler = TextScaler.linear(2);
        final pages = TextPagination.paginate(
          [Paragraph('连续正文' * 30, remoteIndex: 1)],
          width: 280,
          height: 500,
          style: style,
          scaler: scaler,
          direction: TextDirection.ltr,
          comments: true,
          commentPlacement: placement,
          commentRightInset: 8,
        );
        for (final fragment in pages.expand((p) => p)) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 288,
                    child: ReadingParagraph(
                      text: fragment.text,
                      style: style,
                      textScaler: scaler,
                      rightInset: 8,
                      placement: placement,
                      comment:
                          placement == ParagraphCommentPlacement.right ||
                              fragment.endsParagraph
                          ? ParagraphCommentButton(count: 7, onPressed: () {})
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(
            tester.getSize(find.byType(ReadingParagraph)).height,
            closeTo(fragment.height, .01),
          );
          expect(fragment.height + 18, lessThanOrEqualTo(500));
          expect(tester.takeException(), isNull);
        }
      }
    }
  });

  test('小字号短段落在页底放不下气泡时整体移到下一页', () {
    for (final placement in ParagraphCommentPlacement.values) {
      final paragraphs = [
        for (var i = 0; i < 40; i++)
          Paragraph(i.isEven ? '字' * 20 : '短段', remoteIndex: i),
      ];
      final pages = TextPagination.paginate(
        paragraphs,
        width: 280,
        height: 200,
        headingSpace: 47,
        style: const TextStyle(fontSize: 14, height: 1.2),
        scaler: TextScaler.noScaling,
        direction: TextDirection.ltr,
        comments: true,
        commentPlacement: placement,
      );
      for (var i = 0; i < pages.length; i++) {
        expect(
          pages[i].fold<double>(i == 0 ? 47 : 0, (h, f) => h + f.height + 18),
          lessThanOrEqualTo(200.01),
        );
      }
      expect(
        pages.expand((p) => p).map((f) => f.paragraph).toSet(),
        hasLength(40),
      );
    }
  });
}
