import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg_api.dart';
import 'package:unr/sources/sfacg_source.dart';
import 'package:unr/ui/comment_content.dart';
import 'package:unr/ui/comments_sheet.dart';

http.Response ok(Object? data, {int status = 200, String message = ''}) =>
    http.Response(
      jsonEncode({
        'status': {'httpCode': status, 'msg': message},
        'data': data,
      }),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

SfacgSource source(
  Future<http.Response> Function(http.Request) handler, {
  bool loggedIn = true,
}) {
  final api = SfacgApi(client: MockClient(handler));
  if (loggedIn) {
    api.setCookie('.SFCommunity=synthetic; session_APP=synthetic-app');
  }
  return SfacgSource(api);
}

const comment = ParagraphComment(id: '7', author: '其他读者', text: '别人发表的零赞评论');
Map<String, Object> remote(int likes) => {
  'tsukkomiId': 7,
  'postUser': {'nickName': '其他读者'},
  'content': comment.text,
  'favNum': likes,
  'replyNum': 1,
};

void main() {
  test('主段评使用无正文 POST 点赞，读取服务端数量并阻止重复点赞', () async {
    var posts = 0, gets = 0;
    final sf = source((request) async {
      if (request.method == 'POST') {
        expect(request.url.path, '/tsukkomis/0/7/favs');
        expect(request.body, isEmpty);
        expect(
          request.headers['Cookie'],
          contains('session_APP=synthetic-app'),
        );
        expect(request.headers['sfsecurity'], contains('sign='));
        posts++;
        return ok(null, status: 201);
      }
      expect(request.url.path, '/tsukkomis/0/7');
      gets++;
      return ok(remote(1));
    });
    addTearDown(sf.api.close);
    await sf.likeComment(comment);
    expect(sf.likeStatus(comment).value.count, 1);
    expect(sf.likeStatus(comment).value.liked, isTrue);
    await sf.likeComment(comment);
    expect([posts, gets], [1, 1]);
  });

  test('并发点击共用一个请求，未确认之前不虚增数字', () async {
    var posts = 0;
    final pending = Completer<http.Response>();
    final sf = source((_) {
      posts++;
      return pending.future;
    });
    addTearDown(sf.api.close);
    final first = sf.likeComment(comment), second = sf.likeComment(comment);
    expect(first, same(second));
    expect(sf.likeStatus(comment).value.count, 0);
    expect(sf.likeStatus(comment).value.sending, isTrue);
    pending.complete(ok({'favNum': 4}));
    await Future.wait([first, second]);
    expect(posts, 1);
    expect(sf.likeStatus(comment).value.count, 4);
    expect(sf.likeStatus(comment).value.sending, isFalse);
  });

  test('未登录、无效 ID 和回复 ID 不发送请求，不会赞错同编号的主评论', () async {
    var calls = 0;
    final sf = source((_) async {
      calls++;
      return ok(null);
    }, loggedIn: false);
    addTearDown(sf.api.close);
    await expectLater(sf.likeComment(comment), throwsA(isA<SourceException>()));
    expect(sf.likeStatus(comment).value.message, contains('登录'));
    sf.api.setCookie('.SFCommunity=synthetic; session_APP=synthetic-app');
    final reply = SfacgSource.parseComment({
      'replyId': 7,
      'content': '回复',
    }, reply: true);
    expect(reply.isReply, isTrue);
    await expectLater(sf.likeComment(reply), throwsA(isA<SourceException>()));
    await expectLater(
      sf.likeComment(
        const ParagraphComment(id: '../invalid', author: '', text: ''),
      ),
      throwsA(isA<SourceException>()),
    );
    expect(sf.likeStatus(comment).value.message, isNull);
    expect(calls, 0);
  });

  test('失败或结果不明不自动重发，也不改变赞数', () async {
    for (final mode in ['forbidden', 'server', 'network', 'timeout']) {
      var calls = 0;
      final sf = source((_) async {
        calls++;
        if (mode == 'network') throw http.ClientException('lost connection');
        if (mode == 'timeout') throw TimeoutException('timeout');
        return ok(
          null,
          status: mode == 'forbidden' ? 403 : 503,
          message: '拒绝请求',
        );
      });
      await expectLater(
        sf.likeComment(comment),
        throwsA(isA<SourceException>()),
      );
      final status = sf.likeStatus(comment).value;
      expect(calls, 1);
      expect(status.count, 0);
      expect(status.liked, isFalse);
      expect(status.sending, isFalse);
      expect(
        status.message,
        contains(mode == 'forbidden' ? '段评点赞失败' : '结果未确认'),
      );
      sf.api.close();
    }
  });

  test('确认点赞后数量查询失败仍保持已点赞，刷新列表可更新赞数', () async {
    final sf = source((request) async {
      if (request.method == 'POST') return ok(null);
      if (request.url.path == '/tsukkomis/0/7') return ok(null, status: 403);
      return ok([remote(8)]);
    });
    addTearDown(sf.api.close);
    await sf.likeComment(comment);
    expect(sf.likeStatus(comment).value.liked, isTrue);
    expect(sf.likeStatus(comment).value.message, contains('已点赞'));
    await sf.comments(const Chapter(id: '123', title: ''), 1);
    expect(sf.likeStatus(comment).value.count, 8);
    expect(sf.likeStatus(comment).value.liked, isTrue);
    expect(sf.likeStatus(comment).value.message, isNull);
  });

  test('较早的评论列表响应不会覆盖刚确认的赞数，切换账号隔离点赞状态', () async {
    final old = Completer<http.Response>();
    final sf = source((request) async {
      if (request.method == 'POST') return ok({'favNum': 1});
      return old.future;
    });
    addTearDown(sf.api.close);
    final stale = sf.comments(const Chapter(id: '123', title: ''), 1);
    await sf.likeComment(comment);
    old.complete(ok([remote(0)]));
    await stale;
    expect(sf.likeStatus(comment).value.count, 1);
    sf.api.setCookie('.SFCommunity=other-synthetic; session_APP=other-session');
    expect(sf.likeStatus(comment).value.liked, isFalse);
  });

  testWidgets('别人零赞的主段评在列表和回复页原段评中都可以点赞，状态共享', (tester) async {
    var posts = 0;
    final sf = source((request) async {
      if (request.method == 'POST') {
        posts++;
        return ok(null);
      }
      if (request.url.path.endsWith('/replys')) return ok([]);
      if (request.url.path == '/tsukkomis/0/7') return ok(remote(1));
      return ok([remote(0)]);
    });
    addTearDown(sf.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentsSheet(
            source: sf,
            chapter: const Chapter(id: '123', title: ''),
            paragraph: const Paragraph('原文', remoteIndex: 1),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final key = find.byKey(const ValueKey('like-comment-7')).hitTestable();
    expect(tester.widget<TextButton>(key).onPressed, isNotNull);
    expect(find.descendant(of: key, matching: find.text('0')), findsOneWidget);
    await tester.tap(find.text('查看 1 条回复'));
    await tester.pumpAndSettle();
    await tester.tap(key);
    await tester.pumpAndSettle();
    expect(find.descendant(of: key, matching: find.text('1')), findsOneWidget);
    expect(tester.widget<TextButton>(key).onPressed, isNull);
    await tester.tap(find.byTooltip('关闭回复'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: key, matching: find.text('1')), findsOneWidget);
    expect(posts, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点赞按钮在零赞失败后保持可用，重复点击发送中的按钮不增加请求', (tester) async {
    var posts = 0;
    final pending = Completer<http.Response>();
    final sf = source((_) {
      posts++;
      return posts == 1
          ? Future.value(ok(null, status: 403, message: '会话失效'))
          : pending.future;
    });
    addTearDown(sf.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentCard(comment: comment, source: sf),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('like-comment-7'));
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.textContaining('会话失效'), findsOneWidget);
    expect(
      find.descendant(of: button, matching: find.text('0')),
      findsOneWidget,
    );
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await tester.pump();
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    await tester.tap(button);
    expect(posts, 2);
    pending.complete(ok({'favNum': 1}));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: button, matching: find.text('1')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
