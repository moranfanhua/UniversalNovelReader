import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/comments_sheet.dart';
import 'helpers/viewport.dart';
import 'helpers/sfacg_comments.dart';

void main() {
  Future<void> open(WidgetTester tester, SfacgSource source) async {
    addTearDown(source.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentsSheet(
            source: source,
            chapter: chapter,
            paragraph: paragraph,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('段评发送使用登录会话、原始 row 和 UTF-8 内容，成功清除旧计数', () async {
    var posts = 0, heads = 0;
    final sf = source((request) async {
      expect(request.url.path, '/chaps/0/123/tsukkomis');
      if (request.method == 'HEAD') {
        heads++;
        return http.Response(
          '',
          200,
          headers: {'x-total-count': posts == 0 ? '5' : '6'},
        );
      }
      expect(request.method, 'POST');
      posts++;
      expect(request.headers['Cookie'], contains('session_APP=synthetic-app'));
      expect(request.headers['sfsecurity'], contains('sign='));
      expect(jsonDecode(request.body), {'content': text, 'row': 6});
      return response({'tsukkomiId': 9}, status: 201);
    });
    addTearDown(sf.api.close);
    expect(await sf.commentCount(chapter, 6), 5);
    await sf.postComment(chapter, 6, '  $text  ');
    expect(await sf.commentCount(chapter, 6), 6);
    expect([posts, heads], [1, 2]);
  });

  test('未登录、空评论或无效段落不会发送网络请求', () async {
    var requests = 0;
    final sf = source((_) async {
      requests++;
      return response(null);
    }, loggedIn: false);
    addTearDown(sf.api.close);
    await expectLater(
      sf.postComment(chapter, 6, text),
      throwsA(isA<SourceException>()),
    );
    sf.api.setCookie('.SFCommunity=synthetic; session_APP=synthetic-app');
    for (final row in [0, -1]) {
      await expectLater(
        sf.postComment(chapter, row, text),
        throwsA(isA<SourceException>()),
      );
    }
    await expectLater(
      sf.postComment(chapter, 6, ' \n '),
      throwsA(isA<SourceException>()),
    );
    expect(requests, 0);
  });

  test('不明确的发送结果不自动重试，提示先刷新确认', () async {
    for (final failure in ['server', 'network', 'timeout', 'invalid']) {
      var calls = 0;
      final sf = source((_) async {
        calls++;
        if (failure == 'network') throw http.ClientException('connection lost');
        if (failure == 'timeout') throw TimeoutException('timeout');
        if (failure == 'invalid') {
          return http.Response('<html>gateway</html>', 200);
        }
        return response(null, status: 503);
      });
      await expectLater(
        sf.postComment(chapter, 6, text),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            '结果',
            contains('发送结果未确认'),
          ),
        ),
      );
      expect(calls, 1);
      sf.api.close();
    }
  });

  test('发送前正在加载的计数不会覆盖发送后的新计数', () async {
    var heads = 0;
    final oldCount = Completer<http.Response>();
    final sf = source((request) async {
      if (request.method == 'POST') return response(null);
      heads++;
      if (heads == 1) return oldCount.future;
      return http.Response('', 200, headers: {'x-total-count': '6'});
    });
    addTearDown(sf.api.close);
    final old = sf.commentCount(chapter, 6);
    await sf.postComment(chapter, 6, text);
    expect(await sf.commentCount(chapter, 6, refresh: true), 6);
    oldCount.complete(http.Response('', 200, headers: {'x-total-count': '5'}));
    expect(await old, 5);
    expect(await sf.commentCount(chapter, 6), 6);
    expect(heads, 2);
  });

  testWidgets('发送期间防重复，成功清空输入并刷新最新段评', (tester) async {
    var posts = 0, gets = 0;
    final posted = Completer<http.Response>();
    final sf = source((request) async {
      if (request.method == 'POST') {
        posts++;
        return posted.future;
      }
      gets++;
      if (gets > 1) {
        expect(request.url.queryParameters['sort'], 'date');
        expect(request.url.queryParameters['page'], '0');
        expect(request.url.queryParameters['row'], '6');
      }
      return response(gets == 1 ? [] : [comment()]);
    });
    await open(tester, sf);
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.text('发送'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await tester.tap(find.text('发送中…'));
    expect(posts, 1);
    posted.complete(response({'tsukkomiId': 9}, status: 201));
    await tester.pumpAndSettle();
    expect(find.text('段评已发送'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.text('测试读者'), findsOneWidget);
    expect([posts, gets], [1, 2]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('发送失败保留输入，手动刷新可确认不明确的发布结果', (tester) async {
    var posts = 0, gets = 0;
    final sf = source((request) async {
      if (request.method == 'POST') {
        posts++;
        return response(null, status: 503);
      }
      gets++;
      return response(gets == 1 ? [] : [comment()]);
    });
    await open(tester, sf);
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(find.textContaining('发送结果未确认'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      text,
    );
    await tester.tap(find.byTooltip('刷新段评'));
    await tester.pumpAndSettle();
    expect(find.text('测试读者'), findsOneWidget);
    expect([posts, gets], [1, 2]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('成功发送后的列表刷新失败不会误报发送失败', (tester) async {
    var gets = 0, posts = 0;
    final sf = source((request) async {
      if (request.method == 'POST') {
        posts++;
        return response(null);
      }
      gets++;
      return gets == 1
          ? response([])
          : response(null, status: 403, message: '列表暂不可读');
    });
    await open(tester, sf);
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(find.text('段评已发送'), findsOneWidget);
    expect(find.textContaining('列表暂不可读'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(posts, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('未登录仍可看段评，手机键盘不会遮住登录后的输入框', (tester) async {
    setTestViewport(tester, const Size(360, 640));
    addTearDown(tester.view.resetViewInsets);
    final sf = source((_) async => response([]), loggedIn: false);
    await open(tester, sf);
    expect(find.textContaining('请先在“我的 → 账号设置”中'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    sf.api.setCookie('.SFCommunity=synthetic; session_APP=synthetic-app');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showComments(context, sf, chapter, paragraph),
              child: const Text('打开段评'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开段评'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '手机输入');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(TextField)).bottom,
      lessThanOrEqualTo(340),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
