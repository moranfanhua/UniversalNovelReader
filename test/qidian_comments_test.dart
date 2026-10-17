import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/comments_sheet.dart';

const chapter = Chapter(id: '12345', title: '第一章');
const book = Book(
  id: '12',
  source: 'qidian',
  title: '测试作品',
  author: '测试作者',
  chapters: [chapter],
);
const location = CommentLocation(
  book: book,
  chapter: chapter,
  paragraph: Paragraph('正文', remoteIndex: 3),
);
const listPath = '/argus/api/v2/chapterreview/getparagraphscomments';
const countPath = '/argus/api/v1/chapterreview/getparagraphscommentcounts';
const replyPath = '/argus/api/v2/chapterreview/getparagraphscommentsreview';

http.Response ok(Object data) => http.Response.bytes(
  utf8.encode(jsonEncode({'Result': 0, 'Data': data})),
  200,
);

Map<String, Object?> comment(
  String id, {
  bool reply = false,
  String root = '100',
  int time = 1700000000000,
}) => {
  'Id': id,
  'ReviewType': reply ? 2 : 1,
  'RootReviewId': reply ? root : '0',
  'ParagraphId': 3,
  'UserName': reply ? '回复作者' : '段评作者',
  'UserId': 20,
  'Content': reply ? '回复内容' : '段评内容',
  'UserHeadIcon': 'https://example.test/avatar.png',
  'AgreeAmount': 12,
  'ReviewCount': reply ? 0 : 2,
  'RefferContent': '正文',
  'CreateTime': time,
};

QidianCredentials session(String id) => QidianCredentials(
  userId: id,
  ywGuid: id,
  ywKey: 'synthetic',
  token: 'synthetic',
);

QidianSource sourceWith(Future<http.Response> Function(http.Request) handler) {
  final api = QidianApi(client: MockClient(handler));
  addTearDown(api.close);
  return QidianSource(api);
}

void main() {
  test('正文保留 App 原始段号，空行和插图不使段评错位，缓存往返保留编号', () {
    final content = QidianSource.parseContent('第一段\r\n\r\n  第三段\r第四段\n', [
      {
        'Type': 'image',
        'Attach': 0,
        'Sort': 1,
        'Url': 'https://example.test/a',
      },
      {
        'Type': 'image',
        'Attach': 1,
        'Sort': 1,
        'Url': 'https://example.test/b',
      },
    ]);
    expect(content.paragraphs.map((p) => p.remoteIndex), [null, 1, null, 3, 4]);
    expect(
      content.paragraphs.where((p) => p.image == null).map((p) => p.text),
      ['第一段', '第三段', '第四段'],
    );
    expect(
      ChapterContent.fromJson(content.toJson()).toJson(),
      content.toJson(),
    );
  });

  test('整章计数合并并发请求，按作品章节缓存，支持刷新、过期和失败重试', () async {
    var calls = 0, fail = false;
    var now = DateTime.utc(2026, 10, 17);
    final gate = Completer<void>();
    final api = QidianApi(
      clock: () => now,
      client: MockClient((request) async {
        calls++;
        expect(request.method, 'GET');
        expect(request.url.host, 'druidv6.if.qidian.com');
        expect(request.url.path, countPath);
        expect(request.headers['QDSign'], isNotEmpty);
        await gate.future;
        if (fail) throw http.ClientException('offline');
        return ok({
          'ChapterId': 12345,
          'DataList': [
            {'ParagraphId': -1, 'CommentCount': 20},
            {'ParagraphId': 1, 'CommentCount': 4},
            {'ParagraphId': 3, 'CommentCount': 7},
          ],
        });
      }),
    );
    addTearDown(api.close);
    final source = QidianSource(api);
    const first = CommentLocation(
      book: book,
      chapter: chapter,
      paragraph: Paragraph('第一段', remoteIndex: 1),
    );
    final pending = Future.wait([
      source.paragraphCommentCount(location),
      source.paragraphCommentCount(first),
    ]);
    gate.complete();
    expect(await pending, [7, 4]);
    expect(calls, 1);
    expect(await source.paragraphCommentCount(location), 7);
    expect(calls, 1);
    await source.paragraphCommentCount(location, refresh: true);
    expect(calls, 2);
    now = now.add(const Duration(minutes: 3));
    fail = true;
    await expectLater(
      source.paragraphCommentCount(location),
      throwsA(isA<http.ClientException>()),
    );
    fail = false;
    expect(await source.paragraphCommentCount(location), 7);
    expect(calls, 4);
    const anotherBook = Book(
      id: '13',
      source: 'qidian',
      title: '',
      author: '',
      chapters: [chapter],
    );
    await source.paragraphCommentCount(
      const CommentLocation(
        book: anotherBook,
        chapter: chapter,
        paragraph: Paragraph('正文', remoteIndex: 3),
      ),
    );
    expect(calls, 5);
    api.credentials = session('21');
    await source.paragraphCommentCount(location);
    expect(calls, 6);
  });

  test('计数损坏或章节不匹配不会伪装为零，也不会缓存失败结果', () async {
    for (final data in [
      {'ChapterId': 999, 'DataList': []},
      {'ChapterId': 12345},
      {
        'ChapterId': 12345,
        'DataList': [null],
      },
      {
        'ChapterId': 12345,
        'DataList': [
          {'ParagraphId': 3},
        ],
      },
      {
        'ChapterId': 12345,
        'DataList': [
          {'ParagraphId': 3, 'CommentCount': -1},
        ],
      },
      {
        'ChapterId': 12345,
        'DataList': [
          {'ParagraphId': 3, 'CommentCount': 1},
          {'ParagraphId': 3, 'CommentCount': 2},
        ],
      },
    ]) {
      var calls = 0;
      final source = sourceWith((_) async {
        calls++;
        return calls == 1 ? ok(data) : ok({'ChapterId': 12345, 'DataList': []});
      });
      await expectLater(
        source.paragraphCommentCount(location),
        throwsA(isA<SourceException>()),
      );
      expect(await source.paragraphCommentCount(location), 0);
      expect(calls, 2);
    }
  });

  test('App 返回 ChapterId=0 的有效计数仍按请求章节读取', () async {
    final source = sourceWith(
      (_) async => ok({
        'ChapterId': 0,
        'DataList': [
          {'ParagraphId': 3, 'CommentCount': 7},
        ],
      }),
    );
    expect(await source.paragraphCommentCount(location), 7);
  });

  test('热门与最新使用 App 参数，旧协议不发送新版游标，过滤占位并归属内嵌回复', () async {
    final requests = <http.Request>[];
    final source = sourceWith((request) async {
      requests.add(request);
      final params = request.url.queryParameters;
      expect(request.url.path, listPath);
      expect(params['bookId'], '12');
      expect(params['chapterId'], '12345');
      expect(params['paragraphId'], '3');
      expect(params['pz'], '10');
      expect(params['anchorId'], '0');
      expect(params['from'], '0');
      expect(params.containsKey('nextCursor'), isFalse);
      if (params['pg'] == '2') return ok({'PagingMode': 0, 'DataList': []});
      return ok({
        'PagingMode': 0,
        'DataList': [
          comment('100'),
          comment('101', reply: true),
          for (var i = 0; i < 9; i++) {'ReviewType': 4, 'Id': 0},
        ],
      });
    });
    final first = await source.commentPage(location, sort: CommentSort.hot);
    expect(first.items.single.id, '100');
    expect(first.items.single.replies.single.id, '101');
    expect(first.items.single.likes, 12);
    expect(first.items.single.replyCount, 2);
    expect(first.items.single.date, '2023-11-14T22:13:20.000Z');
    expect(first.nextCursor, isNotNull);
    final last = await source.commentPage(
      location,
      cursor: first.nextCursor,
      sort: CommentSort.hot,
    );
    expect(last.nextCursor, isNull);
    await source.commentPage(location, sort: CommentSort.latest);
    expect(requests.map((r) => r.url.queryParameters['type']), [
      '100',
      '100',
      '101',
    ]);
    expect(requests.map((r) => r.url.queryParameters['pg']), ['1', '2', '1']);
  });

  test('新版协议沿用不透明游标且 pg 保持 1，结束标记停止翻页', () async {
    var calls = 0;
    final source = sourceWith((request) async {
      calls++;
      final params = request.url.queryParameters;
      expect(params['pg'], '1');
      expect(params['nextCursor'], calls == 1 ? null : 'opaque/+中文=');
      return ok({
        'PagingMode': 1,
        'NextCursor': calls == 1 ? 'opaque/+中文=' : 'emptyCursor',
        'DataList': calls == 1 ? [comment('100')] : [],
      });
    });
    final first = await source.commentPage(location);
    final last = await source.commentPage(location, cursor: first.nextCursor);
    expect(last.nextCursor, isNull);
    expect(calls, 2);
  });

  test('分页不能复用于其他排序或段落，无效位置不会发请求', () async {
    var calls = 0;
    final source = sourceWith((_) async {
      calls++;
      return ok({'PagingMode': 1, 'NextCursor': 'next', 'DataList': []});
    });
    final first = await source.commentPage(location);
    await expectLater(
      source.commentPage(
        location,
        cursor: first.nextCursor,
        sort: CommentSort.hot,
      ),
      throwsA(isA<SourceException>()),
    );
    for (final paragraph in [
      const Paragraph('旧缓存'),
      const Paragraph('正文', remoteIndex: 0),
      const Paragraph('', image: 'https://example.test/a', remoteIndex: 3),
    ]) {
      await expectLater(
        source.commentPage(
          CommentLocation(book: book, chapter: chapter, paragraph: paragraph),
        ),
        throwsA(isA<SourceException>()),
      );
    }
    await expectLater(
      source.commentPage(location, cursor: '2'),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source.commentPage(
        const CommentLocation(
          chapter: chapter,
          paragraph: Paragraph('正文', remoteIndex: 3),
        ),
      ),
      throwsA(isA<SourceException>()),
    );
    const foreign = Book(
      id: '12',
      source: 'fanqie',
      title: '',
      author: '',
      chapters: [chapter],
    );
    await expectLater(
      source.commentPage(
        const CommentLocation(
          book: foreign,
          chapter: chapter,
          paragraph: Paragraph('正文', remoteIndex: 3),
        ),
      ),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 1);
  });

  test('损坏的返回、段落串线、重复游标和分页协议切换会明确报错', () async {
    for (final data in [
      {'DataList': null},
      {
        'DataList': ['invalid'],
      },
      {
        'DataList': [comment('100')..['ParagraphId'] = 4],
      },
      {
        'BookInfo': {'BookId': 13},
        'DataList': [],
      },
      {'PagingMode': 2, 'DataList': []},
      {'PagingMode': 1, 'NextCursor': '', 'DataList': []},
    ]) {
      final source = sourceWith((_) async => ok(data));
      await expectLater(
        source.commentPage(location),
        throwsA(isA<SourceException>()),
      );
    }
    for (final mode in [0, 1]) {
      var calls = 0;
      final source = sourceWith(
        (_) async => ok({
          'PagingMode': calls++ == 0 ? 1 : mode,
          'NextCursor': 'same',
          'DataList': [],
        }),
      );
      final first = await source.commentPage(location);
      await expectLater(
        source.commentPage(location, cursor: first.nextCursor),
        throwsA(isA<SourceException>()),
      );
    }
  });

  test('回复遵循 App 加载更多行的页码和数量，去重后按旧到新排列', () async {
    var calls = 0;
    final source = sourceWith((request) async {
      calls++;
      expect(request.url.path, replyPath);
      final params = request.url.queryParameters;
      expect(params['rootReviewId'], '100');
      expect(params['type'], '0');
      expect(params['scene'], '0');
      expect(params['pg'], calls == 1 ? '1' : '3');
      expect(params['pz'], calls == 1 ? '20' : '10');
      return ok({
        'DataList': calls == 1
            ? [
                comment('102', reply: true, time: 1700000001000),
                {
                  'ReviewType': 4,
                  'RootReviewId': '100',
                  'PageIndex': 3,
                  'PageSize': 10,
                },
              ]
            : [
                comment('102', reply: true, time: 1700000001000),
                comment('101', reply: true),
              ],
      });
    });
    final replies = await source.repliesFor(
      location,
      const ParagraphComment(id: '100', author: '', text: ''),
    );
    expect(replies.map((r) => r.id), ['101', '102']);
    expect(replies.every((r) => r.isReply), isTrue);
    expect(calls, 2);
  });

  test('回复支持新版游标，页面销毁后停止请求，拒绝错误归属与未推进分页', () async {
    const root = ParagraphComment(id: '100', author: '', text: '');
    var calls = 0, cancelled = false;
    final source = sourceWith((request) async {
      calls++;
      if (calls == 1) {
        expect(request.url.queryParameters.containsKey('nextCursor'), isFalse);
      }
      if (calls == 2) {
        expect(request.url.queryParameters['nextCursor'], 'reply-next');
      }
      return ok({
        'PagingMode': 1,
        'DataList': [
          comment('$calls', reply: true),
          {
            'ReviewType': 4,
            'RootReviewId': '100',
            'NextCursor': calls == 1 ? 'reply-next' : 'emptyCursor',
          },
        ],
      });
    });
    expect((await source.repliesFor(location, root)).length, 2);
    expect(calls, 2);
    await source.repliesFor(location, root, cancelled: () => true);
    expect(calls, 2);
    final cancelSource = sourceWith((_) async {
      cancelled = true;
      return ok({
        'DataList': [
          comment('1', reply: true),
          {
            'ReviewType': 4,
            'RootReviewId': '100',
            'PageIndex': 2,
            'PageSize': 20,
          },
        ],
      });
    });
    expect(
      await cancelSource.repliesFor(location, root, cancelled: () => cancelled),
      isEmpty,
    );
    for (final row in [
      comment('1', reply: true, root: '999'),
      {'ReviewType': 4, 'RootReviewId': '100', 'PageIndex': 1, 'PageSize': 20},
      {'ReviewType': 4, 'RootReviewId': '999', 'PageIndex': 2, 'PageSize': 20},
    ]) {
      final invalid = sourceWith(
        (_) async => ok({
          'DataList': [row],
        }),
      );
      await expectLater(
        invalid.repliesFor(location, root),
        throwsA(isA<SourceException>()),
      );
    }
  });

  test('账号切换拒绝过期列表和计数，不把旧请求缓存给新会话', () async {
    for (final counts in [false, true]) {
      final gate = Completer<http.Response>();
      var calls = 0;
      final source = sourceWith((_) async {
        calls++;
        return calls == 1
            ? gate.future
            : ok({'ChapterId': 12345, 'DataList': []});
      });
      final pending = counts
          ? source.paragraphCommentCount(location)
          : source.commentPage(location);
      final rejected = expectLater(pending, throwsA(isA<SourceException>()));
      source.api.credentials = session('21');
      gate.complete(ok({'ChapterId': 12345, 'DataList': []}));
      await rejected;
      if (counts) {
        expect(await source.paragraphCommentCount(location), 0);
        expect(calls, 2);
      }
    }
  });

  test('图片段评、回复对象和语音占位保持可读，图片地址只接受 HTTP(S)', () async {
    final source = sourceWith(
      (_) async => ok({
        'DataList': [
          comment('100')..['ImageDetail'] = 'https://example.test/comment.png',
          comment('101', reply: true)..['RelatedUser'] = '被回复者',
          comment('102')
            ..['Content'] = ''
            ..['AudioUrl'] = 'https://example.test/voice.mp3',
          comment('103')
            ..['ImageDetail'] = 'file:///private'
            ..['PreImage'] = '//example.test/preview.png',
        ],
      }),
    );
    final items = (await source.commentPage(location)).items;
    final parts = source.commentContent(items.first.text);
    expect(parts.first.text, '段评内容');
    expect(parts.last.image, 'https://example.test/comment.png');
    expect(items.first.replies.single.text, '回复 被回复者：回复内容');
    expect(items[1].text, contains('语音评论'));
    expect(
      source.commentContent(items[2].text).last.image,
      'https://example.test/preview.png',
    );
  });

  for (final width in [390.0, 1400.0]) {
    testWidgets('起点书源自动注册段评面板，宽度 $width 未登录可读取回复并提示登录', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final source = sourceWith(
        (request) async => ok({
          'DataList': [
            comment(
              request.url.path == replyPath ? '101' : '100',
              reply: request.url.path == replyPath,
            ),
          ],
        }),
      );
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('unr-qidian-comments-'),
      ))!;
      addTearDown(() => root.delete(recursive: true));
      final defaultApi = SfacgApi(
        client: MockClient((_) async => throw StateError('Wrong source')),
      );
      addTearDown(defaultApi.close);
      final library = Library(
        root,
        SfacgSource(defaultApi),
        novelSources: [source],
      );
      addTearDown(library.dispose);
      expect(library.commentsFor(book), same(source));
      final capabilities = source.commentCapabilities;
      expect([
        capabilities.post,
        capabilities.reply,
        capabilities.replyToReply,
      ], everyElement(isTrue));
      expect([
        capabilities.likes,
        capabilities.replyLikes,
      ], everyElement(isFalse));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommentsSheet(
              source: source,
              book: book,
              chapter: chapter,
              paragraph: location.paragraph,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('段评内容'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('查看 2 条回复'), findsOneWidget);
      await tester.tap(find.text('查看 2 条回复'));
      await tester.pumpAndSettle();
      expect(find.text('回复内容'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
