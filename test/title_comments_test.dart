import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/domain/reading_preferences.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/comments_sheet.dart';
import 'package:unr/ui/paragraph_comment_button.dart';
import 'package:unr/ui/reading_heading.dart';
import 'package:unr/ui/reader.dart';

class _TitleComments extends CommentSource {
  final counts = <(String, int?)>[];
  final writes = <CommentLocation>[];
  @override
  String get id => 'title-test';
  @override
  String get name => '标题段评测试';
  @override
  bool get hasSession => true;
  @override
  CommentCapabilities get commentCapabilities =>
      const CommentCapabilities(counts: true, post: true);
  @override
  Paragraph chapterTitleParagraph(Chapter chapter) =>
      Paragraph(chapter.title, remoteIndex: 0);
  @override
  Future<int> paragraphCommentCount(
    CommentLocation location, {
    bool refresh = false,
  }) async {
    counts.add((location.chapter.id, location.paragraph.remoteIndex));
    return 4;
  }

  @override
  Future<CommentPage> commentPage(
    CommentLocation location, {
    String? cursor,
    CommentSort sort = CommentSort.latest,
  }) async => const CommentPage([]);
  @override
  Future<void> publishComment(CommentLocation location, String text) async {
    expect(text, '标题评论');
    writes.add(location);
  }
}

class _Library extends Library {
  _Library(_TitleComments comments)
    : super(
        Directory.systemTemp,
        SfacgSource(SfacgApi()),
        commentSources: [comments],
      );
  void showComments(bool value) {
    showParagraphComments = value;
    notifyListeners();
  }

  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async =>
      const ChapterContent([Paragraph('正文首段。', remoteIndex: 1)]);
  @override
  Future<void> save() async => notifyListeners();
  @override
  Future<void> remember(Book book, int chapter, int paragraph) async {
    progress[book.key] = [chapter, paragraph];
  }
}

void main() {
  for (final mode in ReadingMode.values) {
    for (final width in [390.0, 1400.0]) {
      for (final placement in ParagraphCommentPlacement.values) {
        testWidgets('标题可读写且段号独立（${mode.name}，$width，${placement.name}）', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final comments = _TitleComments();
          final library = _Library(comments)
            ..readingMode = mode
            ..paragraphCommentPlacement = placement
            ..showParagraphComments =
                !(mode == ReadingMode.paged && width == 1400);
          addTearDown(library.dispose);
          addTearDown(library.source.api.close);
          final title = '这是一个用于验证标题段评气泡布局的长章节标题' * 3;
          final book = Book(
            id: '1',
            source: 'title-test',
            title: '测试',
            author: '',
            chapters: [
              Chapter(id: '1', title: title),
              const Chapter(id: '2', title: '下一章标题'),
            ],
          );
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(1.5)),
                child: child!,
              ),
              home: ReaderPage(library: library, book: book),
            ),
          );
          await tester.pumpAndSettle();
          if (mode == ReadingMode.paged && width == 1400) {
            expect(find.byType(ParagraphCommentButton), findsNothing);
            expect(comments.counts, isEmpty);
            library.showComments(true);
            await tester.pumpAndSettle();
          }
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 200));
          }
          expect(comments.counts, contains(('1', 0)));
          expect(comments.counts, contains(('1', 1)));
          if (mode == ReadingMode.paged && width == 1400) {
            expect(comments.counts, contains(('2', 0)));
          }
          final heading = find.byType(ReadingHeading).first;
          final badge = find.descendant(
            of: heading,
            matching: find.byType(ParagraphCommentButton),
          );
          expect(badge, findsOneWidget);
          final bounds = tester.getRect(heading);
          final rect = tester.getRect(badge);
          expect(rect.left, greaterThanOrEqualTo(bounds.left));
          expect(rect.right, lessThanOrEqualTo(bounds.right));
          expect(rect.top, greaterThanOrEqualTo(bounds.top));
          expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
          await tester.tap(badge);
          await tester.pumpAndSettle();
          final sheet = tester.widget<CommentsSheet>(
            find.byType(CommentsSheet),
          );
          expect(sheet.paragraph.remoteIndex, 0);
          expect(sheet.paragraph.text, title);
          await tester.enterText(
            find.byKey(const ValueKey('paragraph-comment-draft')),
            '标题评论',
          );
          await tester.tap(find.text('发送'));
          await tester.pumpAndSettle();
          expect(comments.writes.single.chapter.id, '1');
          expect(comments.writes.single.paragraph.remoteIndex, 0);
          expect(library.progress[book.key]?[1] ?? 0, 0);
          if (mode == ReadingMode.paged && width == 1400) {
            Navigator.of(tester.element(find.byType(CommentsSheet))).pop();
            await tester.pumpAndSettle();
            final nextBadge = find.descendant(
              of: find.byType(ReadingHeading).at(1),
              matching: find.byType(ParagraphCommentButton),
            );
            await tester.tap(nextBadge);
            await tester.pumpAndSettle();
            final nextSheet = tester.widget<CommentsSheet>(
              find.byType(CommentsSheet),
            );
            expect(nextSheet.chapter.id, '2');
            expect(nextSheet.paragraph.text, '下一章标题');
            expect(nextSheet.paragraph.remoteIndex, 0);
            await tester.enterText(
              find.byKey(const ValueKey('paragraph-comment-draft')),
              '标题评论',
            );
            await tester.tap(find.text('发送'));
            await tester.pumpAndSettle();
            expect(comments.writes.last.chapter.id, '2');
            expect(comments.writes.last.paragraph.remoteIndex, 0);
            expect(library.progress[book.key]?[0] ?? 0, 0);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }
}
