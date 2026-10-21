import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:unr/domain/models.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/ui/comment_content.dart';
import 'package:unr/ui/comments_sheet.dart';
import 'helpers/sfacg_comments.dart' as fixture;
import 'helpers/viewport.dart';

const root = ParagraphComment(id: '9', author: '楼主', text: '原段评内容');
const replyDraft = ValueKey('comment-reply-draft');
Map<String, Object> reply(int id, String content, String date) => {
  'replyId': id,
  'content': content,
  'replyDate': date,
  'replyUser': {'nickName': '读者$id'},
};

void main() {
  test('回复使用原段评 ID 和登录会话，支持中文换行表情', () async {
    var posts = 0;
    final sf = fixture.source((request) async {
      posts++;
      expect(request.method, 'POST');
      expect(request.url.path, '/tsukkomis/0/9/replys');
      expect(request.headers['Cookie'], contains('session_APP=synthetic-app'));
      expect(request.headers['sfsecurity'], contains('sign='));
      expect(jsonDecode(request.body), {'content': fixture.text});
      return fixture.response({'replyId': 10}, status: 201);
    });
    addTearDown(sf.api.close);
    await sf.postReply(root, '  ${fixture.text}  ');
    expect(posts, 1);
  });

  test('未登录、空内容、回复 ID 或无效原段评不会发送', () async {
    var calls = 0;
    final sf = fixture.source((_) async {
      calls++;
      return fixture.response(null);
    }, loggedIn: false);
    addTearDown(sf.api.close);
    await expectLater(
      sf.postReply(root, '回复'),
      throwsA(isA<SourceException>()),
    );
    sf.api.setCookie('.SFCommunity=synthetic; session_APP=synthetic-app');
    for (final comment in [
      const ParagraphComment(id: '9', author: '其他人', text: '', isReply: true),
      const ParagraphComment(id: 'null', author: '', text: ''),
      const ParagraphComment(id: '0', author: '', text: ''),
    ]) {
      await expectLater(
        sf.postReply(comment, '回复'),
        throwsA(isA<SourceException>()),
      );
    }
    await expectLater(
      sf.postReply(root, ' \n '),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 0);
  });

  test('超时、断线、服务错误和未知响应不重复发送回复', () async {
    for (final failure in ['timeout', 'network', 'server', 'invalid']) {
      var calls = 0;
      final sf = fixture.source((_) async {
        calls++;
        if (failure == 'timeout') throw TimeoutException('timeout');
        if (failure == 'network') throw http.ClientException('connection lost');
        if (failure == 'invalid') return http.Response('gateway', 200);
        return fixture.response(null, status: 503);
      });
      await expectLater(
        sf.postReply(root, '回复'),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            '结果',
            contains('先刷新回复'),
          ),
        ),
      );
      expect(calls, 1);
      sf.api.close();
    }
  });

  testWidgets('零回复评论也能打开输入框，发送后刷新回复和主列表计数', (tester) async {
    var posts = 0, roots = 0;
    final posted = Completer<http.Response>();
    final sf = fixture.source((request) async {
      if (request.method == 'POST') {
        posts++;
        expect(request.url.path, '/tsukkomis/0/9/replys');
        return posted.future;
      }
      if (request.url.path.endsWith('/replys')) {
        return fixture.response(
          posts == 0 ? [] : [reply(10, '新回复', '2026-10-13T12:00:00')],
        );
      }
      roots++;
      return fixture.response([
        {...fixture.comment(), 'replyNum': posts, 'content': root.text},
      ]);
    });
    addTearDown(sf.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentsSheet(
            source: sf,
            chapter: fixture.chapter,
            paragraph: fixture.paragraph,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('查看 0 条回复'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('reply-comment-9')));
    await tester.pumpAndSettle();
    expect(find.byKey(replyDraft), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(replyDraft)).focusNode!.hasFocus,
      isTrue,
    );
    await tester.enterText(find.byKey(replyDraft), '新回复');
    await tester.tap(find.text('发送回复'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(replyDraft)).enabled, isFalse);
    await tester.tap(find.text('发送中…'));
    expect(posts, 1);
    posted.complete(fixture.response(null, status: 201));
    await tester.pumpAndSettle();
    expect(find.text('回复已发送'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(replyDraft)).controller!.text,
      isEmpty,
    );
    expect(
      tester
          .widgetList<CommentCard>(find.byType(CommentCard))
          .last
          .comment
          .text,
      '新回复',
    );
    await tester.tap(find.byTooltip('关闭回复'));
    await tester.pumpAndSettle();
    expect(find.text('查看 1 条回复'), findsOneWidget);
    expect(roots, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点击回复作者后保留草稿，发送仍使用原段评 ID 并按旧到新排列', (tester) async {
    setTestViewport(tester, const Size(800, 1200));
    var sent = false;
    final sf = fixture.source((request) async {
      expect(request.url.path, '/tsukkomis/0/9/replys');
      if (request.method == 'POST') {
        expect(jsonDecode(request.body), {'content': '回复@读者10 我的回复'});
        sent = true;
        return fixture.response(null);
      }
      return fixture.response([
        if (sent) reply(12, '回复@读者10 我的回复', '2026-10-13T12:00:00'),
        reply(11, '新回复', '2026-10-12T12:00:00'),
        reply(10, '旧回复', '2026-10-11T12:00:00'),
      ]);
    });
    addTearDown(sf.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepliesSheet(
            source: sf,
            comment: root,
            location: const CommentLocation(
              chapter: fixture.chapter,
              paragraph: fixture.paragraph,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(replyDraft), '我的回复');
    await tester.ensureVisible(find.byKey(const ValueKey('reply-reply-10')));
    await tester.tap(find.byKey(const ValueKey('reply-reply-10')));
    await tester.pumpAndSettle();
    expect(find.text('回复 @读者10'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(replyDraft)).controller!.text,
      '我的回复',
    );
    await tester.tap(find.text('发送回复'));
    await tester.pumpAndSettle();
    expect(sent, isTrue);
    final cards = tester.widgetList<CommentCard>(find.byType(CommentCard));
    expect(cards.map((c) => c.comment.text), [
      root.text,
      '旧回复',
      '新回复',
      '回复@读者10 我的回复',
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('回复失败保留草稿，成功后的刷新失败不误报发送失败', (tester) async {
    var attempts = 0;
    final sf = fixture.source((request) async {
      if (request.method == 'POST') {
        attempts++;
        return fixture.response(null, status: attempts == 1 ? 503 : 201);
      }
      return attempts < 2
          ? fixture.response([])
          : fixture.response(null, status: 403, message: '回复暂不可读');
    });
    addTearDown(sf.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepliesSheet(
            source: sf,
            comment: root,
            location: const CommentLocation(
              chapter: fixture.chapter,
              paragraph: fixture.paragraph,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(replyDraft), '我的回复');
    await tester.tap(find.text('发送回复'));
    await tester.pumpAndSettle();
    expect(find.textContaining('发送结果未确认'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(replyDraft)).controller!.text,
      '我的回复',
    );
    await tester.tap(find.byTooltip('刷新回复'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送回复'));
    await tester.pumpAndSettle();
    expect(find.text('回复已发送'), findsOneWidget);
    expect(find.textContaining('回复暂不可读'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(replyDraft)).controller!.text,
      isEmpty,
    );
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('未登录可查看回复，手机键盘不会遮住登录后的回复输入框', (tester) async {
    setTestViewport(tester, const Size(360, 640));
    addTearDown(tester.view.resetViewInsets);
    final sf = fixture.source((request) async {
      expect(request.method, 'GET');
      return fixture.response(
        request.url.path.endsWith('/replys') ? [] : [fixture.comment()],
      );
    }, loggedIn: false);
    addTearDown(sf.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentsSheet(
            source: sf,
            chapter: fixture.chapter,
            paragraph: fixture.paragraph,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reply-comment-9')));
    await tester.pumpAndSettle();
    expect(find.byKey(replyDraft), findsNothing);
    expect(find.text('请先在“我的 → 账号设置”中登录菠萝包轻小说后回复评论'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭回复'));
    await tester.pumpAndSettle();
    sf.api.setCookie('.SFCommunity=synthetic; session_APP=synthetic-app');
    await tester.tap(find.byKey(const ValueKey('reply-comment-9')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(replyDraft), '手机输入');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(replyDraft)).bottom,
      lessThanOrEqualTo(340),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
