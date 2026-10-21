import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/domain/reading_preferences.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/paged_chapter.dart';
import 'package:unr/ui/reader.dart';
import 'package:unr/ui/reading_paragraph.dart';
import 'helpers/memory_library.dart';
import 'helpers/viewport.dart';

class TextLayoutLibrary extends TestLibrary
    with MemoryPersistence, MemoryReadingProgress {
  TextLayoutLibrary(this.content)
    : super(
        source: SfacgSource(
          SfacgApi(
            client: MockClient(
              (_) async =>
                  http.Response('', 200, headers: {'x-total-count': '7'}),
            ),
          ),
        ),
      );
  final ChapterContent content;
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async => content;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Use the fonts shipped with the installed Flutter SDK, without adding assets.
    final configFile = File('.dart_tool/package_config.json').absolute;
    final config = jsonDecode(await configFile.readAsString()) as Map;
    final flutter = (config['packages'] as List).cast<Map>().firstWhere(
      (package) => package['name'] == 'flutter',
    );
    final sdk = Directory.fromUri(
      configFile.uri.resolve(flutter['rootUri'] as String),
    ).parent.parent;
    final loader = FontLoader('ReaderLayoutRoboto');
    for (final name in ['roboto-regular.ttf', 'roboto-bold.ttf']) {
      loader.addFont(
        File(
          '${sdk.path}/bin/cache/artifacts/material_fonts/$name',
        ).readAsBytes().then(ByteData.sublistView),
      );
    }
    await loader.load();
  });

  const book = Book(
    id: 'layout',
    title: '正文排版回归',
    author: '',
    chapters: [Chapter(id: '1', title: '第一章')],
  );

  void size(WidgetTester tester, double width) {
    setTestViewport(tester, Size(width, 900));
  }

  void expectLastCharacterVisible(WidgetTester tester, Finder paragraph) {
    final editable = tester
        .state<EditableTextState>(
          find.descendant(of: paragraph, matching: find.byType(EditableText)),
        )
        .renderEditable;
    final text = editable.text!.toPlainText();
    final last = editable
        .getBoxesForSelection(
          TextSelection(baseOffset: text.length - 1, extentOffset: text.length),
        )
        .single;
    expect(
      last.bottom,
      lessThanOrEqualTo(editable.size.height + .01),
      reason: '末字必须位于实际文本视口内，不能只比较外层测量高度',
    );
    expect(last.top, greaterThanOrEqualTo(0));
    final bounds = tester.getRect(paragraph);
    final lastBottom = editable.localToGlobal(Offset(last.right, last.bottom));
    expect(lastBottom.dy, lessThanOrEqualTo(bounds.bottom + .01));
    expect(lastBottom.dx, lessThanOrEqualTo(bounds.right + .01));
  }

  for (final placement in [null, ...ParagraphCommentPlacement.values]) {
    testWidgets(
      'ReaderPage 临界换行保留末字（${placement?.name ?? '关闭段评'}）',
      (tester) async {
        // 15 test-font glyphs fit in 308px until SelectableText reserves its caret.
        size(tester, placement == ParagraphCommentPlacement.right ? 364 : 352);
        final library =
            TextLayoutLibrary(
                const ChapterContent([
                  Paragraph('字字字字字字字字字字字字末', remoteIndex: 1),
                  Paragraph('下一段', remoteIndex: 2),
                ]),
              )
              ..showParagraphComments = placement != null
              ..paragraphCommentPlacement =
                  placement ?? ParagraphCommentPlacement.right;
        addTearDown(library.dispose);
        addTearDown(library.source.api.close);
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(library: library, book: book),
          ),
        );
        await tester.pumpAndSettle();
        final paragraph = find.byType(ReadingParagraph).first;
        expectLastCharacterVisible(tester, paragraph);
        final editable = tester
            .state<EditableTextState>(
              find.descendant(
                of: paragraph,
                matching: find.byType(EditableText),
              ),
            )
            .renderEditable;
        expect(editable.size.height, closeTo(76, .01));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  for (final mode in ReadingMode.values) {
    testWidgets('ReaderPage 系统粗体及文字间距更新后仍显示末字（${mode.name}）', (tester) async {
      const text = 'Wide words more words at the end';
      final theme = ThemeData(fontFamily: 'ReaderLayoutRoboto');
      final normalStyle = theme.textTheme.bodyLarge!.copyWith(
        fontSize: 20,
        height: 1.9,
        fontWeight: FontWeight.w400,
        letterSpacing: .5,
      );
      final measure = TextPainter(
        text: TextSpan(text: '　　$text', style: normalStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      size(tester, measure.width.ceilToDouble() + 48);
      measure.dispose();
      final media = ValueNotifier(const MediaQueryData());
      addTearDown(media.dispose);
      final library =
          TextLayoutLibrary(
              const ChapterContent([
                Paragraph(text),
                Paragraph('next paragraph'),
              ]),
            )
            ..readingMode = mode
            ..showParagraphComments = false
            ..readingFontFamily = 'ReaderLayoutRoboto';
      addTearDown(library.dispose);
      addTearDown(library.source.api.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (context, child) => ValueListenableBuilder(
            valueListenable: media,
            builder: (context, data, _) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(
                    boldText: data.boldText,
                    textScaler: data.textScaler,
                  )
                  .applyTextStyleOverrides(
                    lineHeightScaleFactorOverride:
                        data.lineHeightScaleFactorOverride,
                    letterSpacingOverride: data.letterSpacingOverride,
                    wordSpacingOverride: data.wordSpacingOverride,
                    paragraphSpacingOverride: null,
                  ),
              child: child!,
            ),
          ),
          home: ReaderPage(library: library, book: book),
        ),
      );
      await tester.pumpAndSettle();
      final paragraph = find.byType(ReadingParagraph).first;
      expectLastCharacterVisible(tester, paragraph);
      final normalHeight = tester.getSize(paragraph).height;
      media.value = const MediaQueryData(boldText: true);
      await tester.pumpAndSettle();
      expectLastCharacterVisible(tester, paragraph);
      expect(tester.getSize(paragraph).height, greaterThan(normalHeight));
      for (final data in [
        const MediaQueryData(
          boldText: true,
          textScaler: TextScaler.linear(1.5),
        ),
        const MediaQueryData(
          lineHeightScaleFactorOverride: 2.5,
          letterSpacingOverride: 2,
          wordSpacingOverride: 3,
        ),
      ]) {
        media.value = data;
        await tester.pumpAndSettle();
        expectLastCharacterVisible(tester, paragraph);
      }
      if (mode == ReadingMode.paged) {
        final state = tester.state<PagedChapterState>(
          find.byType(PagedChapter),
        );
        expect(
          state.pages
              .expand((p) => p)
              .where((f) => f.paragraph == 0)
              .map((f) => f.text)
              .join(),
          '　　$text',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final width in [352.0, 1400.0]) {
    for (final placement in ParagraphCommentPlacement.values) {
      testWidgets('粗体长段跨页后每页末字可见（宽度$width，${placement.name}）', (tester) async {
        size(tester, width);
        final text = '${'Wide words and 中文正文😀。' * 70}末';
        final library =
            TextLayoutLibrary(ChapterContent([Paragraph(text, remoteIndex: 1)]))
              ..readingMode = ReadingMode.paged
              ..paragraphCommentPlacement = placement
              ..readingFontFamily = 'ReaderLayoutRoboto';
        addTearDown(library.dispose);
        addTearDown(library.source.api.close);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                boldText: true,
                textScaler: const TextScaler.linear(1.4),
              ),
              child: child!,
            ),
            home: ReaderPage(library: library, book: book),
          ),
        );
        await tester.pumpAndSettle();
        final state = tester.state<PagedChapterState>(
          find.byType(PagedChapter),
        );
        expect(state.pages.length, greaterThan(2));
        expect(
          state.pages.expand((p) => p).map((f) => f.text).join(),
          '　　$text',
        );
        final viewport = tester.getRect(find.byType(PageView));
        for (var spread = 0; spread < state.spreads; spread++) {
          state.controller!.jumpToPage(spread);
          await tester.pumpAndSettle();
          final visible = find.byType(ReadingParagraph).hitTestable();
          expect(visible, findsWidgets);
          for (var i = 0; i < visible.evaluate().length; i++) {
            final paragraph = visible.at(i);
            expectLastCharacterVisible(tester, paragraph);
            expect(
              tester.getRect(paragraph).bottom,
              lessThanOrEqualTo(viewport.bottom - library.verticalMargin + .01),
            );
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
