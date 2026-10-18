import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/book_page_progress.dart';
import 'package:unr/ui/comments_sheet.dart';
import 'package:unr/ui/paged_chapter.dart';
import 'package:unr/ui/paragraph_comment_button.dart';
import 'package:unr/ui/reader.dart';

class _KeyboardComments extends CommentSource {
  @override
  String get id => 'keyboard-test';
  @override
  String get name => '键盘测试';
  @override
  bool get hasSession => true;
  @override
  CommentCapabilities get commentCapabilities =>
      const CommentCapabilities(post: true, replies: true, reply: true);
  @override
  Future<CommentPage> commentPage(
    CommentLocation location, {
    String? cursor,
    CommentSort sort = CommentSort.latest,
  }) async => const CommentPage([
    ParagraphComment(id: '1', author: '测试读者', text: '测试评论', replyCount: 1),
  ]);
  @override
  Future<List<ParagraphComment>> repliesFor(
    CommentLocation location,
    ParagraphComment root, {
    bool Function()? cancelled,
  }) async => [];
}

class _KeyboardLibrary extends Library {
  _KeyboardLibrary()
    : super(
        Directory.systemTemp,
        SfacgSource(SfacgApi()),
        commentSources: [_KeyboardComments()],
      );
  final content = ChapterContent([
    for (var i = 0; i < 18; i++)
      Paragraph('正文段落 $i，${'键盘弹出时保持正文尺寸和阅读位置稳定。' * 3}', remoteIndex: i + 1),
  ]);
  int cacheReads = 0;
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async => content;
  @override
  Future<ChapterContent?> cached(Book book, Chapter chapter) async {
    cacheReads++;
    return content;
  }

  @override
  Future<void> save() async {}
  @override
  Future<void> remember(Book book, int chapter, int paragraph) async {
    progress[book.key] = [chapter, paragraph];
  }
}

void main() {
  const book = Book(
    id: 'keyboard',
    source: 'keyboard-test',
    title: '键盘弹出时保持阅读位置的测试作品',
    author: '',
    chapters: [
      Chapter(id: '1', title: '第一章'),
      Chapter(id: '2', title: '第二章'),
      Chapter(id: '3', title: '第三章'),
    ],
  );

  for (final mode in ReadingMode.values) {
    for (final width in [390.0, 1000.0]) {
      for (final scale in [1.0, 1.5]) {
        testWidgets('段评及回复键盘不改变正文布局与进度（${mode.name}，宽$width，缩放$scale）', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          tester.view.viewPadding = const FakeViewPadding(bottom: 24);
          tester.view.padding = const FakeViewPadding(bottom: 24);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewPadding);
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewInsets);
          final library = _KeyboardLibrary()..readingMode = mode;
          library.progress[book.key] = [0, 3];
          library.pageOffsets[book.key] = 8;
          addTearDown(library.dispose);
          addTearDown(library.source.api.close);
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: ReaderPage(library: library, book: book),
            ),
          );
          await tester.pumpAndSettle();
          final reader = find.byType(ReaderPage);
          final body = find
              .descendant(
                of: reader,
                matching: find.byType(
                  mode == ReadingMode.paged
                      ? PagedChapter
                      : SingleChildScrollView,
                ),
              )
              .first;
          final bodyRect = tester.getRect(body);
          final progress = tester.widget<BookPageProgress>(
            find.byType(BookPageProgress, skipOffstage: false),
          );
          final signature = progress.position.value!.layout.signature;
          final cacheReads = library.cacheReads;
          final pager = mode == ReadingMode.paged
              ? tester.state<PagedChapterState>(body)
              : null;
          final pages = pager?.pages;
          final controller = pager?.controller;
          final page = pager?.page;
          final anchor = (
            progress.position.value!.chapter,
            progress.position.value!.paragraph,
            progress.position.value!.offset,
          );
          final scroll = mode == ReadingMode.scroll
              ? tester.widget<SingleChildScrollView>(body).controller!
              : null;
          final scrollOffset = scroll?.offset;

          void expectStableReader() {
            expect(tester.getRect(body), bodyRect);
            final position = progress.position.value!;
            expect(position.layout.signature, signature);
            expect((
              position.chapter,
              position.paragraph,
              position.offset,
            ), anchor);
            expect(library.cacheReads, cacheReads, reason: '键盘不应触发全书页码重新扫描');
            if (pager != null) {
              expect(pager.pages, same(pages), reason: '键盘不应触发正文重新分页');
              expect(pager.controller, same(controller));
              expect(pager.page, page);
            } else {
              expect(scroll!.offset, scrollOffset);
            }
          }

          await tester.tap(
            find.byType(ParagraphCommentButton).hitTestable().first,
          );
          await tester.pumpAndSettle();
          expect(find.byType(CommentsSheet), findsOneWidget);
          expectStableReader();
          for (final draftKey in [
            'paragraph-comment-draft',
            'comment-reply-draft',
          ]) {
            if (draftKey == 'comment-reply-draft') {
              await tester.tap(find.text('查看 1 条回复'));
              await tester.pumpAndSettle();
              expect(find.byType(RepliesSheet), findsOneWidget);
            }
            final draft = find.byKey(ValueKey(draftKey));
            await tester.tap(draft);
            // Simulate intermediate IME animation frames and navigation padding.
            for (final inset in [60.0, 180.0, 300.0, 180.0, 60.0, 0.0]) {
              tester.view.viewInsets = FakeViewPadding(bottom: inset);
              tester.view.padding = FakeViewPadding(
                bottom: inset == 0 ? 24 : 0,
              );
              await tester.pumpAndSettle();
              expectStableReader();
              expect(
                tester.getRect(draft).bottom,
                lessThanOrEqualTo(844 - inset),
              );
              expect(tester.takeException(), isNull);
            }
          }
          await tester.tap(find.byTooltip('关闭回复'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('关闭段评'));
          await tester.pumpAndSettle();
          expectStableReader();
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }
}
