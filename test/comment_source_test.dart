import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/sources/sfacg_api.dart';
import 'package:unr/sources/sfacg_source.dart';
import 'package:unr/ui/comment_content.dart';
import 'package:unr/ui/comments_sheet.dart';
import 'package:unr/ui/reader.dart';

const chapter = Chapter(id: 'chapter-uuid', title: '第一章');
const paragraph = Paragraph('正文', remoteIndex: 17, remoteId: 'paragraph-token');
const book = Book(
  id: 'book-uuid',
  title: '其他书源作品',
  author: '作者',
  source: 'alternate',
  chapters: [chapter],
);
const root = ParagraphComment(
  id: 'thread-uuid',
  author: '楼主',
  authorId: 'user-root',
  text: '主评论',
  replyCount: 2,
);
const oldReply = ParagraphComment(
  id: 'reply-old',
  author: '老读者',
  authorId: 'user-old',
  text: '旧回复',
  date: '2026-10-12T12:00:00',
  isReply: true,
);
const newReply = ParagraphComment(
  id: 'reply-new',
  author: '新读者',
  text: '新回复',
  date: '2026-10-13T12:00:00',
  isReply: true,
);

// Deliberately different from SFACG: UUID IDs, opaque cursor and independent
// reply target fields. This is a test provider, not another website adapter.
class AlternateComments extends CommentSource {
  AlternateComments({this.readOnly = false, this.replyToReply = true});
  final bool readOnly, replyToReply;
  final cursors = <String?>[];
  final locations = <CommentLocation>[];
  final writes = <Map<String, String>>[];
  final likes = <String, ValueNotifier<CommentLikeStatus>>{};
  int counts = 0;
  @override
  String get id => 'alternate';
  @override
  String get name => '另一个平台';
  @override
  bool get hasSession => true;
  @override
  CommentCapabilities get commentCapabilities => readOnly
      ? const CommentCapabilities()
      : CommentCapabilities(
          counts: true,
          post: true,
          replies: true,
          reply: true,
          replyToReply: replyToReply,
          replyLikes: true,
        );
  @override
  Future<CommentPage> commentPage(
    CommentLocation location, {
    String? cursor,
    CommentSort sort = CommentSort.latest,
  }) async {
    expect(sort, CommentSort.latest);
    locations.add(location);
    cursors.add(cursor);
    return cursor == null
        ? const CommentPage([root], nextCursor: 'next/token:opaque')
        : const CommentPage([
            ParagraphComment(
              id: 'thread-two',
              author: '其他人',
              text: '[em:sfgirl:004]原始文本',
            ),
          ]);
  }

  @override
  Future<int> paragraphCommentCount(
    CommentLocation location, {
    bool refresh = false,
  }) async {
    locations.add(location);
    counts++;
    return 7;
  }

  @override
  Future<List<ParagraphComment>> repliesFor(
    CommentLocation location,
    ParagraphComment root, {
    bool Function()? cancelled,
  }) async {
    expect(root.id, 'thread-uuid');
    locations.add(location);
    return [newReply, oldReply];
  }

  @override
  Future<void> publishComment(CommentLocation location, String text) async {
    writes.add({'paragraphId': location.paragraph.remoteId!, 'body': text});
  }

  @override
  Future<void> postReply(
    ParagraphComment root,
    String text, {
    ParagraphComment? target,
    CommentLocation? location,
  }) async {
    writes.add({
      'threadId': root.id,
      'replyToId': target!.id,
      'replyToUser': target.authorId,
      'body': text,
    });
    locations.add(location!);
  }

  @override
  ValueNotifier<CommentLikeStatus> likeStatus(
    ParagraphComment comment, {
    CommentLocation? location,
    ParagraphComment? root,
  }) => likes.putIfAbsent(
    comment.id,
    () => ValueNotifier(CommentLikeStatus(count: comment.likes)),
  );
  @override
  Future<void> likeComment(
    ParagraphComment comment, {
    CommentLocation? location,
    ParagraphComment? root,
  }) async {
    expect(root!.id, 'thread-uuid');
    locations.add(location!);
    final state = likeStatus(comment);
    state.value = CommentLikeStatus(count: state.value.count + 1, liked: true);
  }

  void dispose() {
    for (final state in likes.values) {
      state.dispose();
    }
  }
}

class AlternateLibrary extends Library {
  AlternateLibrary(SfacgSource sf, CommentSource comments)
    : super(Directory.systemTemp, sf, commentSources: [comments]);
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async =>
      const ChapterContent([paragraph]);
  @override
  Future<void> remember(Book book, int chapter, int paragraph) async {}
}

void main() {
  Future<void> open(WidgetTester tester, AlternateComments source) async {
    addTearDown(source.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentsSheet(
            source: source,
            chapter: chapter,
            paragraph: paragraph,
            book: book,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('不支持写入和排序切换的书源隐藏操作，分页使用书源游标而非固定条数', (tester) async {
    final source = AlternateComments(readOnly: true);
    await open(tester, source);
    expect(find.text('另一个平台 · 段评'), findsOneWidget);
    expect(find.byType(SegmentedButton<CommentSort>), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('回复'), findsNothing);
    expect(
      find.byKey(const ValueKey('like-comment-thread-uuid')),
      findsNothing,
    );
    expect(find.text('查看 2 条回复'), findsNothing);
    await tester.ensureVisible(find.text('加载更多'));
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(source.cursors, [null, 'next/token:opaque']);
    expect(find.text('加载更多'), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(source.writes, isEmpty);
    expect(source.locations.first.book, same(book));
    expect(source.locations.first.paragraph.remoteId, 'paragraph-token');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('发表段评将段落上下文交给对应书源，成功刷新不请求不支持的排序', (tester) async {
    final source = AlternateComments();
    await open(tester, source);
    await tester.enterText(
      find.byKey(const ValueKey('paragraph-comment-draft')),
      '另一个平台的评论',
    );
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(source.writes, [
      {'paragraphId': 'paragraph-token', 'body': '另一个平台的评论'},
    ]);
    expect(source.cursors, [null, null]);
    expect(find.text('段评已发送'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('回复目标和原始文本交给适配器，回复点赞能力独立于主评论', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = AlternateComments();
    await open(tester, source);
    await tester.tap(find.byKey(const ValueKey('reply-comment-thread-uuid')));
    await tester.pumpAndSettle();
    final cards = tester.widgetList<CommentCard>(
      find.descendant(
        of: find.byType(RepliesSheet),
        matching: find.byType(CommentCard),
      ),
    );
    expect(cards.map((card) => card.comment.id), [
      'thread-uuid',
      'reply-old',
      'reply-new',
    ]);
    expect(
      find.byKey(const ValueKey('like-comment-thread-uuid')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('like-comment-reply-old')));
    await tester.pumpAndSettle();
    expect(source.likeStatus(oldReply).value.count, 1);
    await tester.tap(find.byKey(const ValueKey('reply-reply-reply-old')));
    await tester.enterText(
      find.byKey(const ValueKey('comment-reply-draft')),
      '保留原文[custom:smile]',
    );
    await tester.tap(find.text('发送回复'));
    await tester.pumpAndSettle();
    expect(source.writes, [
      {
        'threadId': 'thread-uuid',
        'replyToId': 'reply-old',
        'replyToUser': 'user-old',
        'body': '保留原文[custom:smile]',
      },
    ]);
    expect(
      source.locations.every(
        (location) => location.book?.source == 'alternate',
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('仅支持回复主评论的书源保留主评论回复，隐藏对回复再回复入口', (tester) async {
    final source = AlternateComments(replyToReply: false);
    await open(tester, source);
    await tester.tap(find.byKey(const ValueKey('reply-comment-thread-uuid')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(RepliesSheet),
        matching: find.byKey(const ValueKey('reply-comment-thread-uuid')),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reply-reply-reply-old')), findsNothing);
    expect(find.byKey(const ValueKey('reply-reply-reply-new')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('阅读页按书籍来源请求计数和评论，未知书源及本地书籍不回退菠萝包', (tester) async {
    final source = AlternateComments();
    addTearDown(source.dispose);
    final api = SfacgApi(
      client: MockClient((request) async => throw StateError('不应该访问菠萝包')),
    );
    addTearDown(api.close);
    final library = AlternateLibrary(SfacgSource(api), source);
    addTearDown(library.dispose);
    expect(library.commentsFor(book), same(source));
    for (final id in ['local', 'unknown']) {
      expect(
        library.commentsFor(
          Book(id: '1', title: '', author: '', source: id, chapters: [chapter]),
        ),
        isNull,
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(library: library, book: book),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(source.counts, 1);
    expect(find.text('7'), findsOneWidget);
    await tester.tap(find.text('7'));
    await tester.pumpAndSettle();
    expect(find.text('另一个平台 · 段评'), findsOneWidget);
    expect(
      source.locations.every(
        (location) =>
            location.book == book &&
            location.chapter.id == 'chapter-uuid' &&
            location.paragraph.remoteId == 'paragraph-token',
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
