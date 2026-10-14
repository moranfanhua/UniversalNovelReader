import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_markup.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/ui/comment_content.dart';
import 'package:unr/ui/comments_sheet.dart';
import 'package:unr/ui/reader.dart';

class CommentLibrary extends Library {
  CommentLibrary(super.root, super.source);
  @override
  Future<ChapterContent> read(Book book, Chapter chapter) async =>
      ChapterContent([
        for (var i = 1; i <= 40; i++)
          Paragraph('第$i段正文内容。' * 3, remoteIndex: i),
      ]);
  @override
  Future<void> remember(Book book, int chapter, int paragraph) async {}
}

void main() {
  test('基础、静态和动态表情解析使用官方图片地址，未知标签保留', () {
    String? url(String text) =>
        SfacgMarkup.imageUrl(SfacgMarkup.tags.firstMatch(text)!);
    expect(
      url('[em:sfgirl:004]'),
      'https://rs.sfacg.com/web/common/images/sfgirl/sfgirl004.png',
    );
    expect(url('[em:sfgirl:017]'), endsWith('sfgirl017.png'));
    expect(
      url('[sfem:pack:abc]'),
      'https://rss.sfacg.com/web/account/images/emoji/pack/abc.png',
    );
    expect(url('[dsfem:pack:abc]'), endsWith('/pack/abc.gif'));
    expect(url('[em:unknown:001]'), isNull);
    expect(url('[em:sfgirl:999]'), isNull);
    expect(SfacgMarkup.tags.hasMatch('[sfem:../evil:abc]'), isFalse);
  });
  testWidgets('评论和回复都有真实头像及行内表情', (tester) async {
    const comment = ParagraphComment(
      id: '1',
      author: '作者',
      avatar: 'http://rss.sfacg.com/avatar.jpg',
      text: '前文[em:sfgirl:004]后文[dsfem:pack:abc]',
    );
    final api = SfacgApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentCard(comment: comment, source: SfacgSource(api)),
        ),
      ),
    );
    final images = tester.widgetList<Image>(find.byType(Image));
    expect(images.map((image) => (image.image as NetworkImage).url), [
      'https://rss.sfacg.com/avatar.jpg',
      'https://rs.sfacg.com/web/common/images/sfgirl/sfgirl004.png',
      'https://rss.sfacg.com/web/account/images/emoji/pack/abc.gif',
    ]);
    expect(find.byType(CommentText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('回复区分原段评和独立卡片，并按旧到新呈现', (tester) async {
    final api = SfacgApi(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'status': {'httpCode': 200},
            'data': [
              {
                'replyId': 2,
                'content': '新回复',
                'replyDate': '2026-10-12T12:00:00',
                'replyUser': {'nickName': '乙'},
              },
              {
                'replyId': 1,
                'content': '旧回复',
                'replyDate': '2026-10-11T12:00:00',
                'replyUser': {'nickName': '甲'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepliesSheet(
            location: const CommentLocation(
              chapter: Chapter(id: '1', title: '第一章'),
              paragraph: Paragraph('原文', remoteIndex: 1),
            ),
            source: SfacgSource(api),
            comment: const ParagraphComment(id: '10', author: '楼主', text: '原文'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('原段评'), findsOneWidget);
    expect(find.text('从旧到新'), findsOneWidget);
    final cards = tester
        .widgetList<CommentCard>(find.byType(CommentCard))
        .toList();
    expect(cards.map((card) => card.comment.text), ['原文', '旧回复', '新回复']);
    expect(cards.map((card) => card.label), ['原段评', '回复 1', '回复 2']);
    expect(tester.takeException(), isNull);
    api.close();
  });
  testWidgets('阅读页显示段评数量，仅请求屏幕附近的段落', (tester) async {
    final requested = <int>[];
    final api = SfacgApi(
      client: MockClient((request) async {
        expect(request.method, 'HEAD');
        requested.add(int.parse(request.url.queryParameters['row']!));
        return http.Response('', 200, headers: {'x-total-count': '7'});
      }),
    );
    final library = CommentLibrary(Directory.systemTemp, SfacgSource(api));
    const book = Book(
      id: '1',
      title: '小说',
      author: '作者',
      chapters: [Chapter(id: '1', title: '一')],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(library: library, book: book),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('7'), findsWidgets);
    expect(requested, isNotEmpty);
    final viewport = tester.getRect(find.byType(SingleChildScrollView));
    for (final row in requested) {
      final bounds = tester.getRect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              widget.data == '　　${'第$row段正文内容。' * 3}',
        ),
      );
      expect(bounds.top, lessThan(viewport.bottom + 150));
      expect(bounds.bottom, greaterThan(viewport.top - 150));
    }
    expect(requested.length, lessThan(40));
    expect(requested.toSet().length, requested.length);
    final before = requested.length;
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -900),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(requested.length, greaterThan(before));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.close();
    library.dispose();
  });
}
