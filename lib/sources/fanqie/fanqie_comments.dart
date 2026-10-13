import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../domain/models.dart';
import '../comment_source.dart';
import 'fanqie_api.dart';

abstract class FanqieComments extends CommentSource {
  FanqieComments(this.api);
  final FanqieApi api;
  @override
  bool get hasSession => api.hasSession;
  @override
  CommentCapabilities get commentCapabilities => const CommentCapabilities(
    counts: true,
    post: true,
    replies: true,
    reply: true,
    replyToReply: true,
    likes: true,
    replyLikes: true,
    sorts: {CommentSort.hot, CommentSort.latest},
  );
  final _counts = <String, ({DateTime at, Map<String, int> data})>{};
  final _countRequests = <String, Future<Map<String, int>>>{};
  final _countEpochs = <String, int>{};
  final _likes = <String, ValueNotifier<CommentLikeStatus>>{};
  final _likeRequests = <String, Future<void>>{};
  final _services = <String, Object>{};
  String _session = '';
  int _sessionEpoch = 0;
  static int _int(Object? value) => int.tryParse('$value') ?? 0;
  static Map _map(Object? value) => value is Map ? value : const {};
  static String _id(Object? value) {
    final id = '$value';
    if (!RegExp(r'^[1-9]\d{5,19}$').hasMatch(id)) {
      throw const SourceException('番茄评论标识无效');
    }
    return id;
  }

  static ({String book, String chapter, String version, int row}) _location(
    CommentLocation location,
  ) {
    if (location.book?.source != 'fanqie') {
      throw const SourceException('番茄段评缺少作品信息');
    }
    final version = location.paragraph.remoteId ?? '';
    final row = location.paragraph.remoteIndex;
    if (version.isEmpty || row == null || row < 0) {
      throw const SourceException('番茄段评缺少章节版本或段落编号，请重新下载此章');
    }
    return (
      book: _id(location.book!.id),
      chapter: _id(location.chapter.id),
      version: version,
      row: row,
    );
  }

  static String _countKey(CommentLocation location) {
    final l = _location(location);
    return '${l.book}/${l.chapter}/${l.version}';
  }

  void _invalidate(CommentLocation location) {
    final key = _countKey(location);
    _counts.remove(key);
    _countRequests.remove(key);
    _countEpochs[key] = (_countEpochs[key] ?? 0) + 1;
  }

  Future<Map<String, int>> _chapterCounts(
    CommentLocation location, {
    bool refresh = false,
  }) {
    final l = _location(location), key = _countKey(location);
    final saved = _counts[key];
    if (!refresh &&
        saved != null &&
        DateTime.now().difference(saved.at) < const Duration(minutes: 2)) {
      return Future.value(saved.data);
    }
    return _countRequests.putIfAbsent(key, () {
      final epoch = _countEpochs[key] ?? 0;
      late Future<Map<String, int>> task;
      task =
          (() async {
            final data = await api.app.request(
              '/novel/commentapi/idea/list/${l.chapter}/v1/',
              body: {
                'comment_source': 3,
                'compliance_status': 0,
                'item_id': l.chapter,
                'item_version': l.version,
                'server_channel': 7,
              },
            );
            if ('${data['item_version'] ?? ''}' != l.version ||
                data['data'] is! Map) {
              throw const SourceException('番茄段评计数版本与正文不一致，请刷新章节');
            }
            final counts = <String, int>{};
            for (final entry in (data['data'] as Map).entries) {
              if (int.tryParse('${entry.key}') == null || entry.value is! Map) {
                throw const SourceException('番茄段评计数格式已变化');
              }
              counts['${entry.key}'] = _int(
                entry.value['count'],
              ).clamp(0, 1 << 31);
            }
            if ((_countEpochs[key] ?? 0) == epoch) {
              _counts[key] = (at: DateTime.now(), data: counts);
            }
            return counts;
          })().whenComplete(() {
            if (identical(_countRequests[key], task)) {
              _countRequests.remove(key);
            }
          });
      return task;
    });
  }

  @override
  Future<int> paragraphCommentCount(
    CommentLocation location, {
    bool refresh = false,
  }) async {
    final row = _location(location).row;
    return (await _chapterCounts(location, refresh: refresh))['$row'] ?? 0;
  }

  void _checkSession() {
    if (_session == api.cookie) return;
    _session = api.cookie;
    _sessionEpoch++;
    for (final status in _likes.values) {
      status.value = CommentLikeStatus(count: status.value.count);
    }
  }

  ParagraphComment _comment(Map raw, {bool reply = false}) {
    _checkSession();
    final common = _map(raw['common'] ?? raw['Common']),
        content = _map(common['content']);
    final user = _map(common['user_info']), base = _map(user['base_info']);
    final stat = _map(raw['stat']), action = _map(raw['user_action']);
    final cid = _id(raw[reply ? 'reply_id' : 'comment_id']);
    final seconds = _int(common['create_timestamp']);
    final images = content['image_data_list'];
    var text = '${content['text'] ?? ''}';
    if (images is List && images.isNotEmpty) {
      final urls = <String>[];
      for (final image in images) {
        final value = _map(image);
        final address = value['url'] ?? value['image_url'];
        final valid = address is String ? commentImageAddress(address) : null;
        if (valid != null) urls.add(valid);
      }
      if (urls.isNotEmpty) {
        text = '\u0000fanqie:${jsonEncode({'text': text, 'images': urls})}';
      }
    }
    _services[cid] = common['service_id'] ?? 1;
    final status = _likes.putIfAbsent(
      cid,
      () => ValueNotifier(
        CommentLikeStatus(
          count: _int(stat['digg_count']),
          liked: action['user_digg'] == true,
        ),
      ),
    );
    if (!status.value.sending) {
      status.value = CommentLikeStatus(
        count: _int(stat['digg_count']),
        liked: action['user_digg'] == true,
      );
    }
    return ParagraphComment(
      id: cid,
      author: '${base['user_name'] ?? '读者'}',
      text: text,
      authorId: '${user['user_id'] ?? base['user_id'] ?? ''}',
      avatar: '${base['user_avatar'] ?? ''}',
      likes: _int(stat['digg_count']),
      replyCount: _int(stat['reply_count']),
      isReply: reply,
      paragraphText: '${_map(raw['expand'])['para_src_content'] ?? ''}',
      date: seconds <= 0
          ? ''
          : DateTime.fromMillisecondsSinceEpoch(
              seconds * 1000,
              isUtc: true,
            ).toIso8601String(),
    );
  }

  @override
  List<CommentPart> commentContent(String text) {
    if (!text.startsWith('\u0000fanqie:')) return [CommentPart.text(text)];
    try {
      final data = jsonDecode(text.substring('\u0000fanqie:'.length)) as Map;
      return [
        CommentPart.text('${data['text'] ?? ''}'),
        for (final image in data['images'] as List)
          if (image is String && commentImageAddress(image) != null)
            CommentPart.image(image),
      ];
    } catch (_) {
      return [CommentPart.text(text)];
    }
  }

  static String? _next(Map info, String? cursor) {
    if (info['has_more'] != true) return null;
    final next = '${info['cursor'] ?? ''}';
    if (next.isEmpty || next == cursor) {
      throw const SourceException('番茄评论分页游标无效');
    }
    return next;
  }

  @override
  Future<CommentPage> commentPage(
    CommentLocation location, {
    String? cursor,
    CommentSort sort = CommentSort.latest,
  }) async {
    final l = _location(location);
    final data = await api.app.request(
      '/novel/commentapi/comment/list/${l.chapter}/v1',
      body: {
        'business_param': {
          'book_id': l.book,
          'need_count': cursor == null,
          'para_index': l.row,
          'item_version': l.version,
          'fold_type': 1,
          'item_count': 0,
          'max_item_count': 0,
          'req_type': 0,
        },
        'comment_source': 2,
        'comment_type': 1,
        'count': 20,
        'group_id': l.chapter,
        'group_type': 15,
        'server_channel': 38,
        'sort': sort == CommentSort.hot ? 1 : 3,
        'cursor': ?cursor,
      },
    );
    final list = data['data_list'];
    if (list is! List || data['common_list_info'] is! Map) {
      throw const SourceException('番茄评论列表格式已变化');
    }
    final comments = <ParagraphComment>[];
    for (final entry in list) {
      if (entry is! Map || entry['comment'] is! Map) {
        throw const SourceException('番茄评论内容格式已变化');
      }
      comments.add(_comment(entry['comment'] as Map));
    }
    return CommentPage(
      comments,
      nextCursor: _next(data['common_list_info'] as Map, cursor),
    );
  }

  @override
  Future<List<ParagraphComment>> repliesFor(
    CommentLocation location,
    ParagraphComment root, {
    bool Function()? cancelled,
  }) async {
    final l = _location(location), cid = _id(root.id);
    final replies = <String, ParagraphComment>{}, seen = <String>{};
    var cursor = '';
    for (var page = 0; page < 100; page++) {
      if (cancelled?.call() == true) return orderedReplies(replies.values);
      final data = await api.app.request(
        '/novel/commentapi/reply/list/$cid/v1/',
        body: {
          'aid': 1967,
          'business_param': {
            'book_id': l.book,
            'client_ab_params': '{"comment_dislike_filter":"0"}',
            'need_count': false,
          },
          'comment_id': cid,
          'comment_source': 502,
          'comment_type': 1,
          'compliance_status': 0,
          'count': 20,
          'cursor': cursor,
          'group_id': l.chapter,
          'group_type': 15,
        },
      );
      if (cancelled?.call() == true) return orderedReplies(replies.values);
      if (data['reply_list'] is! List) {
        throw const SourceException('番茄回复列表格式已变化');
      }
      for (final raw in data['reply_list'] as List) {
        if (raw is! Map) throw const SourceException('番茄回复内容格式已变化');
        final item = _comment(raw, reply: true);
        replies[item.id] = item;
      }
      final info = data['comment_list_info'] ?? data['common_list_info'];
      if (info is! Map) throw const SourceException('番茄回复分页格式已变化');
      final next = _next(info, cursor);
      if (next == null) return orderedReplies(replies.values);
      if (!seen.add(next)) throw const SourceException('番茄回复分页游标重复');
      cursor = next;
    }
    throw const SourceException('此段评回复过多，请在官方 App 查看更多回复');
  }

  void _requireSession() {
    if (!hasSession) throw const SourceException('请在“我的 → 账号设置”中导入番茄登录会话');
  }

  static String _text(String text) {
    final value = text.trim();
    if (value.isEmpty || value.runes.length > 1000) {
      throw const SourceException('请输入 1～1000 字的评论内容');
    }
    return value;
  }

  Map<String, dynamic> _business(CommentLocation location) {
    final l = _location(location);
    return {
      'book_id': l.book,
      'item_version': l.version,
      'para_content': location.paragraph.text,
      'pos_v1': {
        'start_para_index': l.row,
        'end_para_index': l.row,
        'start_word_pos': 0,
        'end_word_pos': location.paragraph.text.length,
        'start_media_index': 0,
        'end_media_index': 0,
      },
    };
  }

  @override
  Future<void> publishComment(CommentLocation location, String text) async {
    _requireSession();
    final l = _location(location);
    final data = await api.app.request(
      '/novel/commentapi/comment/add/v1/',
      body: {
        'text': _text(text),
        'group_id': l.chapter,
        'group_type': 15,
        'data_type': 1,
        'comment_type': 0,
        'commit_source': 2,
        'business_param': _business(location),
      },
    );
    if ('${_map(data['comment_info'])['comment_id'] ?? data['comment_id'] ?? ''}'
        .isEmpty) {
      throw const SourceException('番茄未确认段评发送结果，请刷新列表后检查');
    }
    _invalidate(location);
  }

  @override
  Future<void> postReply(
    ParagraphComment root,
    String text, {
    ParagraphComment? target,
    CommentLocation? location,
  }) async {
    _requireSession();
    if (location == null) throw const SourceException('番茄回复缺少章节信息');
    final l = _location(location);
    final reply = target ?? root;
    final data = await api.app.request(
      '/novel/commentapi/reply/add/v1/',
      body: {
        'text': _text(text),
        'group_id': l.chapter,
        'group_type': 15,
        'data_type': 1,
        'commit_source': 8,
        'reply_to_comment_id': _id(root.id),
        'reply_to_userid': reply.authorId,
        if (reply.isReply) 'reply_to_replyid': _id(reply.id),
        'business_param': _business(location),
      },
    );
    if ('${_map(data['reply'])['reply_id'] ?? data['reply_id'] ?? ''}'
        .isEmpty) {
      throw const SourceException('番茄未确认回复发送结果，请刷新列表后检查');
    }
  }

  @override
  ValueListenable<CommentLikeStatus> likeStatus(
    ParagraphComment comment, {
    CommentLocation? location,
    ParagraphComment? root,
  }) {
    _checkSession();
    return _likes.putIfAbsent(
      comment.id,
      () => ValueNotifier(CommentLikeStatus(count: comment.likes)),
    );
  }

  @override
  Future<void> likeComment(
    ParagraphComment comment, {
    CommentLocation? location,
    ParagraphComment? root,
  }) {
    _requireSession();
    if (location == null) throw const SourceException('番茄点赞缺少作品信息');
    _checkSession();
    final l = _location(location), cid = _id(comment.id);
    return _likeRequests.putIfAbsent(cid, () {
      final status = likeStatus(comment) as ValueNotifier<CommentLikeStatus>,
          old = status.value,
          epoch = _sessionEpoch;
      status.value = CommentLikeStatus(
        count: (old.count + (old.liked ? -1 : 1)).clamp(0, 1 << 31),
        liked: !old.liked,
        sending: true,
      );
      return (() async {
        try {
          await api.app.request(
            '/reading/ugc/novel_comment/digg/v',
            body: {
              'book_id': l.book,
              'comment_id': cid,
              'digg_type': old.liked ? 3 : 1,
              'target_type': comment.isReply ? 2 : 1,
              'service_id': _services[cid] ?? 1,
            },
          );
          _checkSession();
          if (epoch == _sessionEpoch) {
            status.value = CommentLikeStatus(
              count: status.value.count,
              liked: status.value.liked,
            );
          }
        } catch (e) {
          _checkSession();
          if (epoch == _sessionEpoch) {
            status.value = CommentLikeStatus(
              count: old.count,
              liked: old.liked,
              message: '$e',
            );
          }
          rethrow;
        } finally {
          _likeRequests.remove(cid);
        }
      })();
    });
  }
}
