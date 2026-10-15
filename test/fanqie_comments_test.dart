import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/fanqie/fanqie_source.dart';

const bid = '7143038691944959011',
    cid = '7173216089122439711',
    rootId = '1234567890123456789',
    replyId = '2234567890123456789';
const location = CommentLocation(
  book: Book(
    id: bid,
    title: '作品',
    author: '作者',
    source: 'fanqie',
    chapters: [],
  ),
  chapter: Chapter(id: cid, title: '章节'),
  paragraph: Paragraph('一段😀文字', remoteIndex: 0, remoteId: 'version-1'),
);
Map<String, dynamic> entry(
  String id, {
  bool reply = false,
  int timestamp = 100,
  int likes = 3,
}) => {
  reply ? 'reply_id' : 'comment_id': id,
  reply ? 'Common' : 'common': {
    'create_timestamp': timestamp,
    'service_id': 1,
    'content': {'text': reply ? '回复正文' : '评论正文'},
    'user_info': {
      'user_id': '3456789012345678901',
      'base_info': {
        'user_name': '读者',
        'user_avatar': 'https://example.com/avatar.png',
      },
    },
  },
  'stat': {'digg_count': likes, 'reply_count': 2},
  'user_action': {'user_digg': false},
};
http.Response response(Object data) => http.Response(
  jsonEncode({'code': 0, 'data': data}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
FanqieApi apiWith(
  Future<http.Response> Function(http.Request) handler, {
  bool session = false,
}) {
  final api = FanqieApi(client: MockClient(handler));
  api.app.restore({'deviceId': '123456789', 'installId': '987654321'});
  if (session) api.setCookie('sessionid=synthetic');
  return api;
}

void main() {
  test('段落计数按章节及正文版本合并请求，刷新失败不覆盖已有计数', () async {
    var calls = 0, broken = false;
    final api = apiWith((req) async {
      calls++;
      final body = jsonDecode(req.body);
      expect(body['item_version'], 'version-1');
      return response({
        'item_version': broken ? 'other' : 'version-1',
        'data': {
          '0': {'count': 7},
          '1': {'count': 2},
        },
      });
    });
    addTearDown(api.close);
    final source = FanqieSource(api);
    final values = await Future.wait([
      source.paragraphCommentCount(location),
      source.paragraphCommentCount(location),
    ]);
    expect(values, [7, 7]);
    expect(calls, 1);
    broken = true;
    await expectLater(
      source.paragraphCommentCount(location, refresh: true),
      throwsA(isA<SourceException>()),
    );
    expect(await source.paragraphCommentCount(location), 7);
    expect(calls, 2);
  });
  test('段评保留真实段号、版本、统计和游标，两种排序发送对应参数', () async {
    var calls = 0;
    final api = apiWith((req) async {
      if (req.method == 'GET') {
        expect(req.url.path, '/reading/ugc/idea/comment_list/v/');
        expect(req.url.queryParameters['sort'], '3');
        expect(req.url.queryParameters['offset'], '20');
        expect(req.url.queryParameters['item_version'], 'version-1');
        return response({
          'comments': [
            {
              'comment_id': rootId,
              'user_info': {
                'user_id': '3456789012345678901',
                'user_name': '读者',
              },
              'text': '最新评论',
              'create_timestamp': 200,
              'digg_count': 3,
              'reply_count': 2,
            },
          ],
          'has_more': false,
          'next_offset': 40,
        });
      }
      final b = jsonDecode(req.body);
      expect(b['group_id'], cid);
      expect(b['group_type'], 15);
      expect(b['business_param']['book_id'], bid);
      expect(b['business_param']['para_index'], 0);
      expect(b['business_param']['item_version'], 'version-1');
      expect(b['server_channel'], 38);
      expect(b['sort'], 1);
      calls++;
      return response({
        'data_list': [
          {'comment': entry(rootId)},
        ],
        'common_list_info': {
          'has_more': calls == 1,
          'cursor': '20',
          'total': 9,
        },
      });
    });
    addTearDown(api.close);
    final source = FanqieSource(api);
    final first = await source.commentPage(location, sort: CommentSort.hot);
    expect(first.nextCursor, '20');
    expect(first.items.single.likes, 3);
    expect(first.items.single.replyCount, 2);
    expect(first.items.single.author, '读者');
    expect(first.items.single.text, '评论正文');
    final last = await source.commentPage(
      location,
      cursor: first.nextCursor,
      sort: CommentSort.latest,
    );
    expect(last.nextCursor, isNull);
    expect(last.items.single.text, '最新评论');
  });
  test('回复分页去重后按时间排列，取消和重复游标不会无限读取', () async {
    var calls = 0;
    final api = apiWith((req) async {
      final b = jsonDecode(req.body);
      expect(b['comment_id'], rootId);
      expect(b['group_id'], cid);
      calls++;
      return response({
        'reply_list': [
          entry(replyId, reply: true, timestamp: 200),
          if (calls == 2)
            entry('3234567890123456789', reply: true, timestamp: 100),
        ],
        'comment_list_info': {
          'has_more': calls == 1,
          'cursor': 'next',
          'total': 2,
        },
      });
    });
    addTearDown(api.close);
    final source = FanqieSource(api);
    const root = ParagraphComment(id: rootId, author: '作者', text: '正文');
    final replies = await source.repliesFor(location, root);
    expect(replies.map((r) => r.id), ['3234567890123456789', replyId]);
    expect(replies.every((r) => r.isReply), isTrue);
    expect(
      await source.repliesFor(location, root, cancelled: () => true),
      isEmpty,
    );
    expect(calls, 2);
    final repeating = apiWith(
      (_) async => response({
        'reply_list': [],
        'comment_list_info': {'has_more': true, 'cursor': 'same'},
      }),
    );
    addTearDown(repeating.close);
    await expectLater(
      FanqieSource(repeating).repliesFor(location, root),
      throwsA(isA<SourceException>()),
    );
  });
  test('发送段评和回复只写指定章节段落，不自动重试且未登录不发请求', () async {
    final bodies = <Map<String, dynamic>>[];
    final api = apiWith((req) async {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
      return response(
        req.url.path.contains('reply')
            ? {
                'reply': {'reply_id': replyId},
              }
            : {
                'comment_info': {'comment_id': rootId},
              },
      );
    }, session: true);
    addTearDown(api.close);
    final source = FanqieSource(api);
    await source.publishComment(location, ' 测试评论 ');
    expect(bodies.single['text'], '测试评论');
    expect(bodies.single['commit_source'], 2);
    expect(
      bodies.single['business_param']['pos_v1'],
      containsPair('start_para_index', 0),
    );
    expect(
      bodies.single['business_param']['pos_v1'],
      containsPair('end_word_pos', 6),
    );
    const root = ParagraphComment(
      id: rootId,
      author: '读者',
      authorId: 'author-1',
      text: '正文',
    );
    const reply = ParagraphComment(
      id: replyId,
      author: '回复者',
      authorId: 'author-2',
      text: '回复',
      isReply: true,
    );
    await source.postReply(root, '回复内容', location: location, target: reply);
    expect(bodies.last['reply_to_comment_id'], rootId);
    expect(bodies.last['reply_to_replyid'], replyId);
    expect(bodies.last['reply_to_userid'], 'author-2');
    expect(bodies.last['commit_source'], 8);
    api.clearSession();
    await expectLater(
      source.publishComment(location, '评论'),
      throwsA(isA<SourceException>()),
    );
    expect(bodies.length, 2);
  });
  test('点赞合并并发操作，服务失败回滚，并区分评论与回复目标', () async {
    final sent = Completer<http.Response>();
    var calls = 0;
    final api = apiWith((req) async {
      calls++;
      final b = jsonDecode(req.body);
      expect(b['book_id'], bid);
      expect(b['target_type'], calls == 1 ? 1 : 2);
      if (calls == 1) return sent.future;
      return http.Response('{"code":403,"data":{}}', 200);
    }, session: true);
    addTearDown(api.close);
    final source = FanqieSource(api);
    const root = ParagraphComment(
      id: rootId,
      author: '读者',
      text: '评论',
      likes: 3,
    );
    final status = source.likeStatus(root);
    final first = source.likeComment(root, location: location),
        second = source.likeComment(root, location: location);
    expect(status.value.sending, isTrue);
    expect(status.value.count, 4);
    expect(status.value.liked, isTrue);
    sent.complete(response({}));
    await Future.wait([first, second]);
    expect(calls, 1);
    expect(status.value.sending, isFalse);
    const reply = ParagraphComment(
      id: replyId,
      author: '读者',
      text: '回复',
      likes: 2,
      isReply: true,
    );
    final replyStatus = source.likeStatus(reply);
    await expectLater(
      source.likeComment(reply, location: location),
      throwsA(isA<SourceException>()),
    );
    expect(replyStatus.value.count, 2);
    expect(replyStatus.value.liked, isFalse);
    expect(replyStatus.value.sending, isFalse);
  });
  test('不伪造未知段落或失败列表为空评，图片评论安全解析', () async {
    var calls = 0;
    final api = apiWith((_) async {
      calls++;
      final raw = entry(rootId);
      (raw['common'] as Map)['content'] = {
        'text': '图评',
        'image_data_list': [
          {'url': 'https://example.com/a.png'},
          {'url': 'javascript:alert(1)'},
        ],
      };
      return response({
        'data_list': [
          {'comment': raw},
        ],
        'common_list_info': {'has_more': false},
      });
    });
    addTearDown(api.close);
    final source = FanqieSource(api);
    final missing = CommentLocation(
      book: location.book,
      chapter: location.chapter,
      paragraph: Paragraph('旧缓存'),
    );
    await expectLater(
      source.commentPage(missing),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 0);
    final page = await source.commentPage(location, sort: CommentSort.hot);
    final parts = source.commentContent(page.items.single.text);
    expect(parts.first.text, '图评');
    expect(
      parts.where((p) => p.image != null).single.image,
      'https://example.com/a.png',
    );
  });
}
