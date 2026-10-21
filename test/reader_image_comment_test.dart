import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/domain/reading_preferences.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/ui/comments_sheet.dart';
import 'package:unr/ui/paragraph_comment_button.dart';
import 'package:unr/ui/reader.dart';
import 'package:unr/ui/reading_paragraph.dart';
import 'helpers/memory_library.dart';
import 'helpers/viewport.dart';

class ImageComments extends CommentSource {
  final opened = <CommentLocation>[];
  @override
  String get id => 'image-test';
  @override
  String get name => '插图测试';
  @override
  bool get hasSession => false;
  @override
  CommentCapabilities get commentCapabilities => const CommentCapabilities();
  @override
  Future<CommentPage> commentPage(
    CommentLocation location, {
    String? cursor,
    CommentSort sort = CommentSort.latest,
  }) async {
    opened.add(location);
    return const CommentPage([]);
  }
}

class ImageCommentLibrary extends TestLibrary
    with MemoryPersistence, MemoryReadingProgress {
  ImageCommentLibrary(ImageComments comments)
    : super(commentSources: [comments]);
  final imageBytes = Completer<Uint8List>();
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async =>
      const ChapterContent([
        Paragraph('', image: 'test-image', remoteIndex: 7),
        Paragraph('插图之后的正文'),
      ]);
  @override
  Future<Uint8List> loadImage(Book book, String url) => imageBytes.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixtures = <String, Uint8List>{};
  setUpAll(() async {
    for (final entry in {
      '有效小图': const Size(1, 1),
      '宽横幅': const Size(1200, 12),
      '普通插图': const Size(100, 60),
    }.entries) {
      final recorder = ui.PictureRecorder();
      Canvas(
        recorder,
      ).drawRect(Offset.zero & entry.value, Paint()..color = Colors.green);
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        entry.value.width.toInt(),
        entry.value.height.toInt(),
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      fixtures[entry.key] = data!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
    }
    fixtures['解码失败占位'] = Uint8List.fromList([0, 1, 2]);
  });

  const book = Book(
    id: 'images',
    source: 'image-test',
    title: '插图段评',
    author: '',
    chapters: [Chapter(id: '1', title: '第一章')],
  );

  Future<void> open(WidgetTester tester, ImageCommentLibrary library) async {
    setTestViewport(tester, const Size(390, 844));
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(library: library, book: book),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> load(
    WidgetTester tester,
    ImageCommentLibrary library,
    Uint8List bytes,
  ) async {
    library.imageBytes.complete(bytes);
    await tester.pump();
    await tester.runAsync(
      () => precacheImage(
        MemoryImage(bytes),
        tester.element(find.byType(BookImage)),
        onError: (_, _) {},
      ),
    );
    await tester.pumpAndSettle();
  }

  void expectCompleteButton(WidgetTester tester) {
    final paragraph = tester.getRect(find.byType(ReadingParagraph).first);
    final button = tester.getRect(find.byType(ParagraphCommentButton));
    expect(button.width, closeTo(28, .01));
    expect(button.height, closeTo(28, .01));
    expect(
      button.top,
      greaterThanOrEqualTo(paragraph.top),
      reason: '气泡顶部必须在图片段落内，不能溢出后被 Stack 裁切',
    );
    expect(button.bottom, lessThanOrEqualTo(paragraph.bottom));
    expect(button.left, greaterThanOrEqualTo(paragraph.left));
    expect(button.right, lessThanOrEqualTo(paragraph.right));
    expect(find.byType(ParagraphCommentButton).hitTestable(), findsOneWidget);
  }

  for (final placement in ParagraphCommentPlacement.values) {
    for (final fixture in ['有效小图', '宽横幅', '解码失败占位', '普通插图']) {
      testWidgets('ReaderPage $fixture 保留完整气泡且中心可打开段评（${placement.name}）', (
        tester,
      ) async {
        final comments = ImageComments();
        final library = ImageCommentLibrary(comments)
          ..paragraphCommentPlacement = placement;
        await open(tester, library);
        expectCompleteButton(tester);
        await load(tester, library, fixtures[fixture]!);
        final image = tester.getSize(find.byType(BookImage));
        if (fixture == '普通插图') {
          expect(image, const Size(100, 60));
          expect(
            tester.getSize(find.byType(ReadingParagraph).first).height,
            60,
          );
        } else {
          expect(image.height, lessThan(28));
          if (fixture == '解码失败占位') {
            expect(find.text('无法显示此插图'), findsOneWidget);
          }
        }
        expectCompleteButton(tester);
        await tester.tapAt(
          tester.getCenter(find.byType(ParagraphCommentButton)),
        );
        await tester.pumpAndSettle();
        expect(find.byType(CommentsSheet), findsOneWidget);
        expect(comments.opened, hasLength(1));
        expect(comments.opened.single.chapter.id, '1');
        expect(comments.opened.single.paragraph.remoteIndex, 7);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('关闭段评时小图保持原始高度', (tester) async {
    final library = ImageCommentLibrary(ImageComments())
      ..showParagraphComments = false;
    await open(tester, library);
    await load(tester, library, fixtures['有效小图']!);
    expect(find.byType(ParagraphCommentButton), findsNothing);
    expect(tester.getSize(find.byType(ReadingParagraph).first).height, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
