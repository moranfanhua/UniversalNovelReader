import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_crypto.dart';
import 'package:unr/sources/ciweimao/ciweimao_source.dart';

const chapter = Chapter(id: '101', title: '合成章节');
const location = CommentLocation(
  book: Book(
    id: '12',
    source: 'ciweimao',
    title: '合成作品',
    author: '测试',
    chapters: [chapter],
  ),
  chapter: chapter,
  paragraph: Paragraph('合成段落', remoteIndex: 1),
);
const root = ParagraphComment(
  id: '900',
  author: '合成读者',
  authorId: '200',
  text: '段评',
  likes: 3,
);
const reply = ParagraphComment(
  id: '901',
  author: '回复读者',
  authorId: '201',
  text: '回复',
  isReply: true,
  likes: 2,
);
http.Response ok(Object? data) => http.Response(
  CiweimaoCrypto.encrypt(jsonEncode({'code': 100000, 'data': data})),
  200,
);
Map<String, Object> entry(
  String id, {
  bool reply = false,
  int likes = 3,
  bool liked = false,
  String date = '2026-10-17 08:00:00',
}) => {
  reply ? 'tsukkomi_reply_id' : 'tsukkomi_id': id,
  if (reply) 'tsukkomi_id': root.id,
  reply ? 'tsukkomi_reply_content' : 'tsukkomi_content': '合成内容',
  'reader_info': {
    'reader_id': '200',
    'reader_name': '合成读者',
    'avatar_thumb_url': 'https://e1.kuangxiangit.com/avatar.png',
  },
  'like_amount': '$likes',
  'is_like': liked ? '1' : '0',
  'reply_num': '2',
  'ctime': date,
  if (!reply) 'paragraph_index': '1',
};
CiweimaoApi apiWith(
  Future<http.Response> Function(http.Request) handler, {
  bool guest = false,
}) => CiweimaoApi(client: MockClient(handler))
  ..restoreSession(
    CiweimaoCredentials(
      account: 'synthetic-account',
      token: 'synthetic-token-1234',
      readerId: '106',
      guest: guest,
    ),
  );

void main() {
  test('同章计数合并请求并缓存，缺失段落为零，损坏刷新保留旧缓存', () async {
    var calls = 0, broken = false;
    final api = apiWith((r) async {
      calls++;
      expect(r.url.path, '/chapter/get_tsukkomi_num');
      return ok({
        'tsukkomi_num_info': broken
            ? null
            : [
                {'paragraph_index': '1', 'tsukkomi_num': '7'},
                {'paragraph_index': '3', 'tsukkomi_num': '2'},
              ],
      });
    });
    addTearDown(api.close);
    final source = CiweimaoSource(api);
    final missing = CommentLocation(
      book: location.book,
      chapter: chapter,
      paragraph: const Paragraph('另一段', remoteIndex: 2),
    );
    expect(
      await Future.wait([
        source.paragraphCommentCount(location),
        source.paragraphCommentCount(missing),
      ]),
      [7, 0],
    );
    expect(calls, 1);
    broken = true;
    await expectLater(
      source.paragraphCommentCount(location, refresh: true),
      throwsA(isA<SourceException>()),
    );
    expect(await source.paragraphCommentCount(location), 7);
    expect(calls, 2);
  });
  test('计数迟到响应不覆盖发表评论后的状态，即使写结果未确认也会失效旧计数', () async {
    final old = Completer<http.Response>(), started = Completer<void>();
    var reads = 0, writes = 0;
    final api = apiWith((r) async {
      if (r.url.path == '/chapter/add_tsukkomi') {
        writes++;
        throw TimeoutException('synthetic');
      }
      reads++;
      if (reads == 1) {
        started.complete();
        return old.future;
      }
      return ok({
        'tsukkomi_num_info': [
          {'paragraph_index': 1, 'tsukkomi_num': 8},
        ],
      });
    });
    addTearDown(api.close);
    final source = CiweimaoSource(api);
    final pending = source.paragraphCommentCount(location);
    final checked = expectLater(pending, throwsA(isA<SourceException>()));
    await started.future;
    await expectLater(
      source.publishComment(location, '合成段评'),
      throwsA(
        isA<SourceException>().having(
          (e) => e.message,
          'message',
          contains('结果未确认'),
        ),
      ),
    );
    expect(await source.paragraphCommentCount(location), 8);
    old.complete(
      ok({
        'tsukkomi_num_info': [
          {'paragraph_index': 1, 'tsukkomi_num': 7},
        ],
      }),
    );
    await checked;
    expect(await source.paragraphCommentCount(location), 8);
    expect(reads, 2);
    expect(writes, 1);
  });
  test('段评分页、热度排序、作者与图片解析符合 App 字段', () async {
    var calls = 0;
    final api = apiWith((r) async {
      calls++;
      expect(r.url.path, '/chapter/get_paragraph_tsukkomi_list_new');
      expect(r.bodyFields['paragraph_index'], '1');
      expect(r.bodyFields['page'], calls == 1 ? '2' : '0');
      expect(r.bodyFields['filter_type'], calls == 1 ? 'hot' : isNull);
      return ok({
        'paragraph_info': {'book_id': '12', 'chapter_id': '101'},
        'tsukkomi_list': [
          for (var i = 0; i < 20; i++)
            {
              ...entry('${900 + i}', liked: true),
              if (i == 0)
                'emoticon_url': 'http://e1.kuangxiangit.com/picture.png',
              if (i == 0) 'hot_reply': [entry('1000', reply: true)],
            },
        ],
      });
    }, guest: true);
    addTearDown(api.close);
    final source = CiweimaoSource(api);
    final page = await source.commentPage(
      location,
      cursor: '2',
      sort: CommentSort.hot,
    );
    expect(page.items, hasLength(20));
    expect(page.nextCursor, '3');
    expect(page.items.first.authorId, '200');
    expect(page.items.first.replies.single.isReply, isTrue);
    expect(source.likeStatus(page.items.first).value.liked, isTrue);
    expect(
      source.commentContent(page.items.first.text).last.image,
      'https://e1.kuangxiangit.com/picture.png',
    );
    await source.commentPage(location);
    expect(source.commentCapabilities.replyLikes, isTrue);
  });
  test('段落错配、非法游标和无段号的作者后记不发出可写请求', () async {
    var calls = 0;
    final api = apiWith((_) async {
      calls++;
      return ok({
        'tsukkomi_list': [
          {...entry('900'), 'paragraph_index': 2},
        ],
      });
    });
    addTearDown(api.close);
    final source = CiweimaoSource(api);
    await expectLater(
      source.commentPage(location),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source.commentPage(location, cursor: '-1'),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source.publishComment(
        const CommentLocation(chapter: chapter, paragraph: Paragraph('作者后记')),
        '合成',
      ),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 1);
  });
  test('回复读取全部分页后按时间、编号升序展示，支持取消', () async {
    var calls = 0;
    final api = apiWith((r) async {
      calls++;
      expect(r.bodyFields['tsukkomi_id'], root.id);
      expect(r.url.path, '/chapter/get_paragraph_tsukkomi_reply_list');
      return ok({
        'tsukkomi_reply_list': calls == 1
            ? [
                for (var i = 0; i < 20; i++)
                  entry('${940 - i}', reply: true, date: '2026-10-17 09:00:00'),
              ]
            : [entry('901', reply: true, date: '2026-10-17 08:00:00')],
      });
    });
    addTearDown(api.close);
    final source = CiweimaoSource(api);
    final result = await source.repliesFor(location, root);
    expect(result, hasLength(21));
    expect(result.first.id, '901');
    expect(result[1].id, '921');
    expect(
      await source.repliesFor(location, root, cancelled: () => true),
      isEmpty,
    );
    expect(calls, 2);
  });
  test('回复重复满页会报错，不能显示成已加载完整对话', () async {
    var calls = 0;
    final api = apiWith((_) async {
      calls++;
      return ok({
        'tsukkomi_reply_list': [
          for (var i = 0; i < 20; i++) entry('${901 + i}', reply: true),
        ],
      });
    });
    addTearDown(api.close);
    await expectLater(
      CiweimaoSource(api).repliesFor(location, root),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 2);
  });
  test('段评、回复和回复目标使用 App 参数，重复点击合并写入', () async {
    var posts = 0;
    final response = Completer<http.Response>(), started = Completer<void>();
    final api = apiWith((r) async {
      expect(r.bodyFields['book_id'], '12');
      expect(r.bodyFields['chapter_id'], '101');
      expect(r.bodyFields['paragraph_index'], '1');
      expect(r.bodyFields['is_combo'], '0');
      if (r.url.path == '/chapter/add_tsukkomi') {
        posts++;
        started.complete();
        expect(r.bodyFields['tsukkomi_content'], '测试段评');
        return response.future;
      }
      expect(r.url.path, '/chapter/add_tsukkomi_reply');
      expect(r.bodyFields['tsukkomi_id'], root.id);
      expect(r.bodyFields['reader_id2'], reply.authorId);
      expect(r.bodyFields['for_tsukkomi_reply_id'], reply.id);
      expect(r.bodyFields['tsukkomi_reply_content'], '回复正文');
      return ok({});
    });
    addTearDown(api.close);
    final source = CiweimaoSource(api);
    final pending = [
      source.publishComment(location, ' 测试段评 '),
      source.publishComment(location, '测试段评'),
    ];
    await started.future;
    expect(posts, 1);
    response.complete(ok({}));
    await Future.wait(pending);
    await source.postReply(root, '回复正文', target: reply, location: location);
    expect(posts, 1);
  });
  test('游客不能发表、回复或点赞，所有写操作都不联网', () async {
    var calls = 0;
    final api = apiWith((_) async {
      calls++;
      return ok({});
    }, guest: true);
    addTearDown(api.close);
    final source = CiweimaoSource(api);
    await expectLater(
      source.publishComment(location, '测试'),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source.postReply(root, '测试', location: location),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source.likeComment(root),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 0);
  });
  test('点赞合并请求并核对服务端赞数，已赞确认不盲目累加', () async {
    var writes = 0;
    final started = Completer<void>(), response = Completer<http.Response>();
    final api = apiWith((r) async {
      if (r.url.path == '/chapter/like_tsukkomi') {
        writes++;
        started.complete();
        return response.future;
      }
      return ok({
        'tsukkomi_list': [entry('900', likes: 8, liked: true)],
      });
    });
    addTearDown(api.close);
    final source = CiweimaoSource(api);
    final state = source.likeStatus(root);
    final a = source.likeComment(root, location: location),
        b = source.likeComment(root, location: location);
    await started.future;
    expect(state.value.sending, isTrue);
    expect(writes, 1);
    response.complete(ok({}));
    await Future.wait([a, b]);
    expect(state.value.count, 8);
    expect(state.value.liked, isTrue);
    await source.likeComment(root, location: location);
    expect(writes, 1);
  });
  test('回复点赞调用独立接口，刷新失败保留确认状态且不污染同编号段评', () async {
    var writes = 0;
    final api = apiWith((r) async {
      writes++;
      expect(r.url.path, '/chapter/tsukkomi_reply_attr');
      expect(r.bodyFields['tsukkomi_reply_id'], '900');
      expect(r.bodyFields['attr_type'], '1');
      expect(r.bodyFields['tsukkomi_id'], isNull);
      return ok(null);
    });
    addTearDown(api.close);
    final source = CiweimaoSource(api);
    const sameIdReply = ParagraphComment(
      id: '900',
      author: '合成',
      text: '合成',
      likes: 2,
      isReply: true,
    );
    await source.likeComment(sameIdReply);
    expect(source.likeStatus(sameIdReply).value.liked, isTrue);
    expect(source.likeStatus(sameIdReply).value.count, 2);
    expect(source.likeStatus(root).value.liked, isFalse);
    expect(writes, 1);
  });
  test('点赞结果未确认不重发或标记已赞，切换账号清除旧点赞视图', () async {
    var calls = 0;
    final api = apiWith((_) async {
      calls++;
      throw TimeoutException('synthetic');
    });
    addTearDown(api.close);
    final source = CiweimaoSource(api), state = CiweimaoSource(api);
    await expectLater(
      source.likeComment(root),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 1);
    expect(source.likeStatus(root).value.liked, isFalse);
    expect(source.likeStatus(root).value.message, contains('未确认'));
    final old = state.likeStatus(root);
    api.restoreSession(
      CiweimaoCredentials(
        account: 'new-account',
        token: 'synthetic-token-5678',
        readerId: '107',
      ),
    );
    expect(identical(old, state.likeStatus(root)), isFalse);
  });
}
