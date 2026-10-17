import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_source.dart';
import 'package:unr/ui/comments_sheet.dart';

const chapter = Chapter(id: '12345', title: '第一章');
const book = Book(
  id: '12',
  source: 'qidian',
  title: '测试作品',
  author: '',
  chapters: [chapter],
);
const location = CommentLocation(
  book: book,
  chapter: chapter,
  paragraph: Paragraph('原始正文', remoteIndex: 3),
);
const root = ParagraphComment(
  id: '100',
  author: '楼主',
  authorId: '20',
  text: '主评论',
);
const reply = ParagraphComment(
  id: '101',
  author: '回复者',
  authorId: '21',
  text: '回复正文',
  isReply: true,
);
const writePath = '/argus/api/v2/chapterreview/addcomment';
const countPath = '/argus/api/v1/chapterreview/getparagraphscommentcounts';

http.Response ok(Object data) => http.Response.bytes(
  utf8.encode(jsonEncode({'Result': 0, 'Data': data})),
  200,
);
QidianCredentials session(String id) => QidianCredentials(
  userId: id,
  ywGuid: id,
  ywKey: 'synthetic',
  token: 'synthetic',
);
QidianSource sourceWith(
  Future<http.Response> Function(http.Request) handler, {
  bool loggedIn = true,
}) {
  final api = QidianApi(client: MockClient(handler));
  if (loggedIn) api.credentials = session('10');
  addTearDown(api.close);
  return QidianSource(api);
}

Map<String, Object?> row({bool reply = false}) => {
  'Id': reply ? '101' : '100',
  'ReviewType': reply ? 2 : 1,
  'RootReviewId': reply ? '100' : '0',
  'ParagraphId': 3,
  'UserId': reply ? '21' : '20',
  'UserName': reply ? '回复者' : '楼主',
  'Content': reply ? '回复正文' : '主评论',
  'RelatedUser': reply ? '楼主' : '',
  'CreateTime': 1700000000000,
  'ReviewCount': reply ? 0 : 1,
};

void main() {
  test('段评使用官方 App POST、会话签名和原始段号，回复使用目标评论 ID 与类型', () async {
    final writes = <Map<String, String>>[];
    final source = sourceWith((request) async {
      expect(request.method, 'POST');
      expect(request.url.host, 'druidv6.if.qidian.com');
      expect(request.url.path, writePath);
      expect(request.url.hasQuery, isFalse);
      expect(request.headers['cookie'], contains('cmfuToken=synthetic'));
      expect(request.headers['QDSign'], isNotEmpty);
      writes.add(request.bodyFields);
      return ok({'Id': '200'});
    });
    await source.publishComment(location, '  中文\n😀  ');
    await source.postReply(root, '回复楼主', location: location);
    await source.postReply(root, '回复楼中楼', location: location, target: reply);
    expect(writes.map((body) => body['type']), ['2', '10', '13']);
    expect(writes.map((body) => body['quoteReviewId']), [null, '100', '101']);
    expect(writes.map((body) => body['quoteUserId']), [null, '20', '21']);
    expect(writes.map((body) => body['refferContent']), [
      '原始正文',
      '主评论',
      '回复正文',
    ]);
    expect(writes.first['content'], '中文\n😀');
    for (final body in writes) {
      expect(body['bookId'], '12');
      expect(body['chapterId'], '12345');
      expect(body['paragraphId'], '3');
      expect(body['isSyncDynamic'], '0');
      expect(body['chapterSourceType'], '0');
      expect(body['timeStamp'], '0');
      expect(body['banId'], '0');
      expect(body['sessionKey'], '');
      expect(body['captchaTicket'], '');
      expect(body['rootReviewId'], isNull);
    }
  });

  test('已获取的回复使用原始引用内容，不把显示用回复前缀写入请求', () async {
    final writes = <Map<String, String>>[];
    final source = sourceWith((request) async {
      if (request.method == 'POST') {
        writes.add(request.bodyFields);
        return ok({'Id': '200'});
      }
      return ok({
        'DataList': [row(), row(reply: true)],
      });
    });
    final loaded = (await source.commentPage(location)).items.single;
    expect(loaded.replies.single.text, '回复 楼主：回复正文');
    await source.postReply(
      loaded,
      '新回复',
      location: location,
      target: loaded.replies.single,
    );
    expect(writes.single['refferContent'], '回复正文');
    final other = CommentLocation(
      book: book,
      chapter: chapter,
      paragraph: const Paragraph('其他段落', remoteIndex: 4),
    );
    await expectLater(
      source.postReply(loaded, '错误段落', location: other),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source.postReply(
        const ParagraphComment(id: '999', author: '', text: ''),
        '错误主评论',
        location: location,
        target: loaded.replies.single,
      ),
      throwsA(isA<SourceException>()),
    );
    expect(writes.length, 1);
  });

  test('未登录、空内容和无效回复目标不发送请求', () async {
    var requests = 0;
    final source = sourceWith((_) async {
      requests++;
      return ok({'Id': '200'});
    }, loggedIn: false);
    await expectLater(
      source.publishComment(location, '正文'),
      throwsA(isA<SourceException>()),
    );
    source.api.credentials = session('10');
    await expectLater(
      source.publishComment(location, ' \n '),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source.postReply(root, '正文'),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source.postReply(reply, '正文', location: location),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source.postReply(
        root,
        '正文',
        location: location,
        target: const ParagraphComment(id: '999', author: '', text: ''),
      ),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source.postReply(
        root,
        '正文',
        location: location,
        target: const ParagraphComment(
          id: '101',
          author: '',
          text: '',
          isReply: true,
        ),
      ),
      throwsA(isA<SourceException>()),
    );
    expect(requests, 0);
  });

  test('同一段落的并发发送被拒绝，确认成功后允许下一次主动发送', () async {
    final gate = Completer<http.Response>();
    final started = Completer<void>();
    var posts = 0;
    final source = sourceWith((_) async {
      if (++posts == 1) {
        started.complete();
        return gate.future;
      }
      return ok({'Id': '201'});
    });
    final sending = source.publishComment(location, '一次发送');
    await started.future;
    await expectLater(
      source.publishComment(location, '重复点击'),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source.postReply(root, '重复回复', location: location),
      throwsA(isA<SourceException>()),
    );
    expect(posts, 1);
    gate.complete(ok({'Id': '200'}));
    await sending;
    await source.publishComment(location, '第二次主动发送');
    expect(posts, 2);
  });

  test('发送结果未确认与风险拦截不重发，也不把 Result=0 当作成功', () async {
    for (final data in [
      <String, Object?>{},
      {'Id': 0},
      {'Id': 'invalid'},
      {
        'Id': '200',
        'RiskConf': {'BanId': 1},
      },
      {
        'Id': '200',
        'RiskConf': {'BanId': 2},
      },
      {'Id': '200', 'RiskConf': 'invalid'},
    ]) {
      var posts = 0;
      final source = sourceWith((_) async {
        posts++;
        return ok(data);
      });
      await expectLater(
        source.publishComment(location, '正文'),
        throwsA(isA<SourceException>()),
      );
      expect(posts, 1);
      expect(source.hasSession, isTrue);
    }
    for (final error in [
      http.ClientException('network'),
      TimeoutException('timeout'),
    ]) {
      var posts = 0;
      final source = sourceWith((_) async {
        posts++;
        throw error;
      });
      await expectLater(
        source.publishComment(location, '正文'),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            'uncertain',
            contains('未确认'),
          ),
        ),
      );
      expect(posts, 1);
    }
    final expired = sourceWith(
      (_) async => http.Response('{"Result":-2}', 200),
    );
    await expectLater(
      expired.publishComment(location, '正文'),
      throwsA(
        isA<SourceException>().having((e) => e.code, 'expired session', -2),
      ),
    );
    expect(expired.hasSession, isTrue);
  });

  test('发送使旧计数和进行中的计数失效，迟到结果不会覆盖最新计数', () async {
    final countGate = Completer<http.Response>();
    var reads = 0;
    final source = sourceWith((request) async {
      if (request.method == 'POST') return ok({'Id': '200'});
      expect(request.url.path, countPath);
      return ++reads == 1
          ? countGate.future
          : ok({
              'ChapterId': 0,
              'DataList': [
                {'ParagraphId': 3, 'CommentCount': 2},
              ],
            });
    });
    final stale = source.paragraphCommentCount(location);
    final rejected = expectLater(stale, throwsA(isA<SourceException>()));
    await source.publishComment(location, '新评论');
    expect(await source.paragraphCommentCount(location), 2);
    countGate.complete(
      ok({
        'ChapterId': 0,
        'DataList': [
          {'ParagraphId': 3, 'CommentCount': 1},
        ],
      }),
    );
    await rejected;
    expect(await source.paragraphCommentCount(location), 2);
    expect(reads, 2);
  });

  test('发送期间切换账号不向新账号确认旧请求成功', () async {
    final gate = Completer<http.Response>();
    final source = sourceWith((_) async => gate.future);
    final pending = source.publishComment(location, '正文');
    final rejected = expectLater(
      pending,
      throwsA(
        isA<SourceException>().having(
          (e) => e.message,
          'session changed',
          contains('原账号'),
        ),
      ),
    );
    source.api.credentials = session('11');
    gate.complete(ok({'Id': '200'}));
    await rejected;
  });

  for (final width in [390.0, 1400.0]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('登录后可发送段评，阻止重复点击并刷新最新列表（宽 $width，缩放 $scale）', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final gate = Completer<http.Response>();
        var posts = 0;
        final sorts = <String?>[];
        final source = sourceWith((request) async {
          if (request.method == 'POST') {
            posts++;
            return gate.future;
          }
          sorts.add(request.url.queryParameters['type']);
          return ok({
            'DataList': [row()],
          });
        });
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: CommentsSheet(
                source: source,
                chapter: chapter,
                paragraph: location.paragraph,
                book: book,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('paragraph-comment-draft')),
          '测试发送',
        );
        await tester.tap(find.text('发送'));
        await tester.pump();
        expect(posts, 1);
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isFalse,
        );
        await tester.tap(find.text('发送中…'));
        expect(posts, 1);
        gate.complete(ok({'Id': '200'}));
        await tester.pumpAndSettle();
        expect(find.text('段评已发送'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        expect(sorts, ['100', '101']);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('未确认或安全验证拦截保留草稿，并显示可理解的错误', (tester) async {
    var posts = 0;
    final source = sourceWith((request) async {
      if (request.method == 'POST') {
        posts++;
        return posts == 1
            ? ok({})
            : ok({
                'RiskConf': {'BanId': 2},
              });
      }
      return ok({'DataList': []});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentsSheet(
            source: source,
            chapter: chapter,
            paragraph: location.paragraph,
            book: book,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '保留草稿');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(find.textContaining('发送结果未确认'), findsOneWidget);
    expect(posts, 1);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '保留草稿',
    );
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(find.textContaining('安全验证'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '保留草稿',
    );
    expect(posts, 2);
  });

  testWidgets('楼中楼可选中回复对象，发送使用回复目标及原始引用内容', (tester) async {
    Map<String, String>? sent;
    final source = sourceWith((request) async {
      if (request.method == 'POST') {
        sent = request.bodyFields;
        return ok({'Id': '200'});
      }
      return ok({
        'DataList': [row(reply: true)],
      });
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepliesSheet(source: source, comment: root, location: location),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '回复').last);
    await tester.pumpAndSettle();
    expect(find.text('回复 @回复者'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '新的楼中楼回复');
    await tester.tap(find.text('发送回复'));
    await tester.pumpAndSettle();
    expect(sent?['type'], '13');
    expect(sent?['quoteReviewId'], '101');
    expect(sent?['refferContent'], '回复正文');
    expect(find.text('回复已发送'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}
