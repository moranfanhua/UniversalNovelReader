import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../domain/models.dart';
import '../comment_source.dart';
import 'ciweimao_api.dart';
import 'ciweimao_parser.dart';

abstract class CiweimaoComments extends CommentSource {
  CiweimaoComments(this.api);
  final CiweimaoApi api;
  final _counts = <String, ({DateTime at, Map<int, int> values})>{};
  final _countRequests = <String, Future<Map<int, int>>>{};
  final _countEpochs = <String, int>{};
  final _likes = <String, ValueNotifier<CommentLikeStatus>>{};
  final _likeVersions = <String, int>{};
  final _likeRequests = <String, Future<void>>{};
  final _writes = <String, Future<void>>{};
  int _likeEpoch = 0;

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
    sorts: {CommentSort.latest, CommentSort.hot},
  );

  static String _commentId(String value) {
    if (!RegExp(r'^[1-9]\d{0,18}$').hasMatch(value)) {
      throw const SourceException('刺猬猫评论编号无效');
    }
    return value;
  }

  static int _number(Object? value, {int fallback = 0}) {
    final n = int.tryParse('${value ?? fallback}');
    if (n == null || n < 0) throw const SourceException('刺猬猫段评统计格式已变化');
    return n;
  }

  static void _location(CommentLocation location, {bool bookRequired = false}) {
    CiweimaoParser.numericId(location.chapter.id);
    final row = location.paragraph.remoteIndex;
    final book = location.book;
    if (row == null ||
        row < 1 ||
        bookRequired && book == null ||
        book != null &&
            (book.source != 'ciweimao' ||
                !book.chapters.any((c) => c.id == location.chapter.id))) {
      throw const SourceException('刺猬猫段落与作品信息不匹配');
    }
    if (book != null) CiweimaoParser.numericId(book.id);
  }

  String _countKey(CommentLocation location) =>
      '${api.sessionGeneration}/${location.chapter.id}';

  @override
  Future<int> paragraphCommentCount(
    CommentLocation location, {
    bool refresh = false,
  }) async {
    _location(location);
    await api.ensureSession();
    final key = _countKey(location),
        epoch = _countEpochs[_countKey(location)] ?? 0;
    final cached = _counts[key];
    if (!refresh &&
        cached != null &&
        api.clock().difference(cached.at) < const Duration(minutes: 2)) {
      return cached.values[location.paragraph.remoteIndex!] ?? 0;
    }
    final requestKey = '$key/$epoch';
    final values = await _countRequests.putIfAbsent(requestKey, () async {
      try {
        final data = await api.request('chapter/get_tsukkomi_num', {
          'chapter_id': location.chapter.id,
        });
        final result = <int, int>{};
        for (final raw in CiweimaoParser.list(
          data['tsukkomi_num_info'],
          '段评计数',
        )) {
          final info = CiweimaoParser.object(raw, '段评计数');
          final row = _number(info['paragraph_index'], fallback: -1);
          if (result.containsKey(row)) {
            throw const SourceException('刺猬猫返回了重复的段落计数');
          }
          result[row] = _number(info['tsukkomi_num'], fallback: -1);
        }
        if ((_countEpochs[key] ?? 0) == epoch) {
          _counts[key] = (at: api.clock(), values: result);
          if (_counts.length > 128) _counts.remove(_counts.keys.first);
        } else {
          throw const SourceException('刺猬猫段评已变化，请刷新计数');
        }
        return result;
      } finally {
        _countRequests.remove(requestKey);
      }
    });
    return values[location.paragraph.remoteIndex!] ?? 0;
  }

  static int _page(String? cursor) {
    if (cursor == null) return 0;
    final page = int.tryParse(cursor);
    if (page == null || page < 0 || page >= 10000) {
      throw const SourceException('刺猬猫段评分页无效');
    }
    return page;
  }

  @override
  Future<CommentPage> commentPage(
    CommentLocation location, {
    String? cursor,
    CommentSort sort = CommentSort.latest,
  }) async {
    _location(location);
    final page = _page(cursor), epoch = _likeEpoch;
    final data = await api.request('chapter/get_paragraph_tsukkomi_list_new', {
      'chapter_id': location.chapter.id,
      'paragraph_index': '${location.paragraph.remoteIndex}',
      'page': '$page',
      'count': '20',
      if (sort == CommentSort.hot) 'filter_type': 'hot',
    });
    final paragraph = data['paragraph_info'];
    if (paragraph is Map &&
        (paragraph['chapter_id'] != null &&
                '${paragraph['chapter_id']}' != location.chapter.id ||
            location.book != null &&
                paragraph['book_id'] != null &&
                '${paragraph['book_id']}' != location.book!.id)) {
      throw const SourceException('刺猬猫返回的段评与作品、章节不匹配');
    }
    final rows = CiweimaoParser.list(data['tsukkomi_list'], '段评列表');
    final seen = <String>{}, items = <ParagraphComment>[];
    for (final raw in rows) {
      final info = CiweimaoParser.object(raw, '段评');
      if (info['chapter_id'] != null &&
              '${info['chapter_id']}' != location.chapter.id ||
          info['paragraph_index'] != null &&
              _number(info['paragraph_index']) !=
                  location.paragraph.remoteIndex ||
          location.book != null &&
              info['book_id'] != null &&
              '${info['book_id']}' != location.book!.id) {
        throw const SourceException('刺猬猫返回了其他段落的评论');
      }
      final comment = _parse(info, epoch: epoch);
      if (!seen.add(comment.id)) throw const SourceException('刺猬猫段评分页重复，请重试');
      items.add(comment);
    }
    return CommentPage(
      items,
      nextCursor: rows.length == 20 ? '${page + 1}' : null,
    );
  }

  ParagraphComment _parse(
    Map<String, dynamic> info, {
    bool reply = false,
    required int epoch,
  }) {
    final reader = CiweimaoParser.object(info['reader_info'], '评论作者');
    final id = _commentId(
      '${info[reply ? 'tsukkomi_reply_id' : 'tsukkomi_id']}',
    );
    var text =
        '${info[reply ? 'tsukkomi_reply_content' : 'tsukkomi_content'] ?? ''}';
    if (reply && '${info['reader_name2'] ?? ''}'.isNotEmpty) {
      text = '回复 @${info['reader_name2']}：$text';
    }
    final picture = CiweimaoParser.imageAddress(
      '${info['emoticon_url'] ?? ''}',
    );
    if (picture != null) text += '\n[img]$picture[/img]';
    final nested = info['hot_reply'];
    final comment = ParagraphComment(
      id: id,
      author: '${reader['reader_name'] ?? '读者'}',
      authorId: '${reader['reader_id'] ?? ''}',
      avatar: '${reader['avatar_thumb_url'] ?? reader['avatar_url'] ?? ''}',
      text: text,
      likes: _number(info['like_amount']),
      replyCount: reply ? 0 : _number(info['reply_num']),
      date: '${info['ctime'] ?? ''}',
      isReply: reply,
      replies: !reply && nested is List
          ? nested
                .map(
                  (v) => _parse(
                    CiweimaoParser.object(v, '段评回复'),
                    reply: true,
                    epoch: epoch,
                  ),
                )
                .toList()
          : const [],
    );
    final key = _likeKey(comment);
    final state = _likes.putIfAbsent(
      key,
      () => ValueNotifier(
        CommentLikeStatus(
          count: comment.likes,
          liked: '${info['is_like']}' == '1',
        ),
      ),
    );
    if (!state.value.sending && (_likeVersions[key] ?? 0) <= epoch) {
      state.value = CommentLikeStatus(
        count: comment.likes,
        liked: '${info['is_like']}' == '1',
      );
    }
    return comment;
  }

  @override
  Future<List<ParagraphComment>> repliesFor(
    CommentLocation location,
    ParagraphComment root, {
    bool Function()? cancelled,
  }) async {
    _location(location);
    if (root.isReply) throw const SourceException('请选择原段评读取回复');
    _commentId(root.id);
    if (cancelled?.call() == true) return [];
    final found = <String, ParagraphComment>{};
    await api.ensureSession();
    final generation = api.sessionGeneration;
    for (var page = 0; page < 500; page++) {
      if (cancelled?.call() == true) return [];
      api.checkSession(generation);
      final epoch = _likeEpoch;
      final data = await api.request(
        'chapter/get_paragraph_tsukkomi_reply_list',
        {'tsukkomi_id': root.id, 'page': '$page', 'count': '20'},
      );
      if (cancelled?.call() == true) return [];
      final rows = CiweimaoParser.list(data['tsukkomi_reply_list'], '段评回复');
      final before = found.length;
      for (final raw in rows) {
        final info = CiweimaoParser.object(raw, '段评回复');
        if (info['tsukkomi_id'] != null &&
            '${info['tsukkomi_id']}' != root.id) {
          throw const SourceException('刺猬猫返回了其他段评的回复');
        }
        final reply = _parse(info, reply: true, epoch: epoch);
        found.putIfAbsent(reply.id, () => reply);
      }
      if (rows.length < 20) return orderedReplies(found.values);
      if (before == found.length) throw const SourceException('刺猬猫回复分页重复，请重试');
    }
    throw const SourceException('刺猬猫回复过多，未能完整获取');
  }

  @override
  List<ParagraphComment> orderedReplies(Iterable<ParagraphComment> comments) {
    final result = comments.toList();
    result.sort((a, b) {
      final first = CiweimaoParser.time(a.date),
          second = CiweimaoParser.time(b.date);
      final date = first != null && second != null
          ? first.compareTo(second)
          : 0;
      return date != 0
          ? date
          : BigInt.parse(a.id).compareTo(BigInt.parse(b.id));
    });
    return result;
  }

  void _requireSession() {
    if (!hasSession) throw const SourceException('请先在“我的 → 账号设置”登录刺猬猫后操作段评');
  }

  Future<void> _write(String path, Map<String, String> params) {
    _requireSession();
    final key =
        '${api.sessionGeneration}/$path/${sha256.convert(utf8.encode(jsonEncode(params)))}';
    return _writes.putIfAbsent(
      key,
      () => api
          .request(path, params, write: true)
          .then<void>((_) {})
          .whenComplete(() {
            _writes.remove(key);
          }),
    );
  }

  @override
  Future<void> publishComment(CommentLocation location, String text) async {
    _location(location, bookRequired: true);
    _requireSession();
    final content = text.trim();
    if (content.isEmpty) throw const SourceException('请输入评论内容');
    final key = _countKey(location);
    try {
      await _write('chapter/add_tsukkomi', {
        'chapter_id': location.chapter.id,
        'book_id': location.book!.id,
        'paragraph_index': '${location.paragraph.remoteIndex}',
        'tsukkomi_content': content,
        'is_combo': '0',
        'combo_type': '0',
      });
    } finally {
      _counts.remove(key);
      _countEpochs[key] = (_countEpochs[key] ?? 0) + 1;
    }
  }

  @override
  Future<void> postReply(
    ParagraphComment root,
    String text, {
    ParagraphComment? target,
    CommentLocation? location,
  }) async {
    if (location == null) throw const SourceException('回复缺少刺猬猫段落信息');
    _location(location, bookRequired: true);
    _requireSession();
    if (root.isReply) throw const SourceException('原段评信息无效');
    _commentId(root.id);
    final content = text.trim();
    if (content.isEmpty) throw const SourceException('请输入回复内容');
    if (target?.isReply == true) {
      _commentId(target!.id);
      _commentId(target.authorId);
    }
    await _write('chapter/add_tsukkomi_reply', {
      'tsukkomi_id': root.id,
      'book_id': location.book!.id,
      'chapter_id': location.chapter.id,
      'paragraph_index': '${location.paragraph.remoteIndex}',
      'tsukkomi_reply_content': content,
      'is_combo': '0',
      'combo_type': '0',
      if (target?.isReply == true) 'reader_id2': target!.authorId,
      if (target?.isReply == true) 'for_tsukkomi_reply_id': target!.id,
    });
  }

  String _likeKey(ParagraphComment comment) =>
      '${api.sessionGeneration}/${comment.isReply ? 'reply' : 'comment'}/${comment.id}';
  @override
  ValueNotifier<CommentLikeStatus> likeStatus(
    ParagraphComment comment, {
    CommentLocation? location,
    ParagraphComment? root,
  }) => _likes.putIfAbsent(
    _likeKey(comment),
    () => ValueNotifier(CommentLikeStatus(count: comment.likes)),
  );

  @override
  Future<void> likeComment(
    ParagraphComment comment, {
    CommentLocation? location,
    ParagraphComment? root,
  }) {
    try {
      _requireSession();
      _commentId(comment.id);
      if (location != null) _location(location);
    } catch (error) {
      return Future.error(error);
    }
    final state = likeStatus(comment);
    if (state.value.liked) return Future.value();
    final key = _likeKey(comment);
    return _likeRequests.putIfAbsent(
      key,
      () => _like(comment, state, location: location, root: root).whenComplete(
        () {
          _likeRequests.remove(key);
        },
      ),
    );
  }

  Future<void> _like(
    ParagraphComment comment,
    ValueNotifier<CommentLikeStatus> state, {
    CommentLocation? location,
    ParagraphComment? root,
  }) async {
    final key = _likeKey(comment), before = state.value.count;
    final generation = api.sessionGeneration;
    _likeVersions[key] = ++_likeEpoch;
    state.value = CommentLikeStatus(count: before, sending: true);
    try {
      await _write(
        comment.isReply
            ? 'chapter/tsukkomi_reply_attr'
            : 'chapter/like_tsukkomi',
        {
          comment.isReply ? 'tsukkomi_reply_id' : 'tsukkomi_id': comment.id,
          if (comment.isReply) 'attr_type': '1',
        },
      );
      api.checkSession(generation);
    } catch (error) {
      _likeVersions[key] = ++_likeEpoch;
      state.value = CommentLikeStatus(count: before, message: '$error');
      rethrow;
    }
    // A success may acknowledge an existing like. Obtain the actual count when
    // the current paragraph/reply page contains it, otherwise keep the old count.
    ParagraphComment? refreshed;
    try {
      if (location != null && !comment.isReply) {
        final page = await commentPage(location);
        refreshed = page.items.where((c) => c.id == comment.id).firstOrNull;
      } else if (location != null && root != null) {
        final data = await api.request(
          'chapter/get_paragraph_tsukkomi_reply_list',
          {'tsukkomi_id': root.id, 'page': '0', 'count': '20'},
        );
        for (final raw in CiweimaoParser.list(
          data['tsukkomi_reply_list'],
          '回复',
        )) {
          final info = CiweimaoParser.object(raw, '回复');
          if ('${info['tsukkomi_reply_id']}' == comment.id) {
            refreshed = _parse(info, reply: true, epoch: _likeEpoch);
          }
        }
      }
      api.checkSession(generation);
    } catch (_) {
      /* The like itself has already been acknowledged. */
    }
    _likeVersions[key] = ++_likeEpoch;
    state.value = CommentLikeStatus(
      count: refreshed?.likes ?? before,
      liked: true,
      message: refreshed == null ? '已点赞，请刷新评论列表更新赞数' : null,
    );
  }

  @override
  String? avatarAddress(String address) => CiweimaoParser.imageAddress(address);
  @override
  List<CommentPart> commentContent(String text) {
    final parts = <CommentPart>[];
    var offset = 0;
    for (final match in RegExp(r'\[img\]([^\[\]]+)\[/img\]').allMatches(text)) {
      if (match.start > offset) {
        parts.add(CommentPart.text(text.substring(offset, match.start)));
      }
      final address = CiweimaoParser.imageAddress(match[1]!.trim());
      parts.add(
        address == null
            ? CommentPart.text(match[0]!)
            : CommentPart.image(address),
      );
      offset = match.end;
    }
    if (offset < text.length) {
      parts.add(CommentPart.text(text.substring(offset)));
    }
    return parts;
  }
}
