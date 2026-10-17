import 'dart:convert';

import '../../domain/models.dart';
import '../comment_source.dart';
import 'qidian_api.dart';

/// Chapter reviews from the official Android App's chapterreview API.
abstract class QidianComments extends CommentSource {
  QidianComments(this.api);
  final QidianApi api;
  final _counts = <String, ({DateTime at, Map<int, int> values})>{};
  final _countRequests = <String, Future<Map<int, int>>>{};
  final _countEpochs = <String, int>{};
  final _writes = <String>{};
  final _reviewContexts =
      <String, ({String location, String root, String quote})>{};
  QidianCredentials? _countSession;

  @override
  bool get hasSession => api.hasSession;
  @override
  CommentCapabilities get commentCapabilities => const CommentCapabilities(
    counts: true,
    post: true,
    replies: true,
    reply: true,
    replyToReply: true,
    sorts: {CommentSort.hot, CommentSort.latest},
  );

  static String _id(Object? value, {int digits = 19}) {
    final id = '$value';
    if (!RegExp('^[1-9]\\d{0,${digits - 1}}\$').hasMatch(id)) {
      throw const SourceException('起点段评编号无效');
    }
    return id;
  }

  static int _number(Object? value, {int fallback = 0}) {
    final number = int.tryParse('${value ?? fallback}');
    if (number == null || number < 0) {
      throw const SourceException('起点段评数据格式已变化');
    }
    return number;
  }

  static ({String book, String chapter, int row}) _location(
    CommentLocation location,
  ) {
    final book = location.book, row = location.paragraph.remoteIndex;
    if (book == null ||
        book.source != 'qidian' ||
        !book.chapters.any((c) => c.id == location.chapter.id)) {
      throw const SourceException('起点段评与作品、章节不匹配');
    }
    if (row == null || row < 1 || location.paragraph.image != null) {
      throw const SourceException('起点段评缺少原始段号，请重新下载此章');
    }
    return (
      book: _id(book.id, digits: 12),
      chapter: _id(location.chapter.id, digits: 12),
      row: row,
    );
  }

  void _checkSession(QidianCredentials? session) {
    if (!identical(session, api.credentials)) {
      throw const SourceException('起点账号已切换，请刷新段评');
    }
  }

  @override
  Future<int> paragraphCommentCount(
    CommentLocation location, {
    bool refresh = false,
  }) async {
    final l = _location(location), session = api.credentials;
    if (!identical(_countSession, session)) {
      _counts.clear();
      _countRequests.clear();
      _countEpochs.clear();
      _countSession = session;
    }
    final key = '${l.book}/${l.chapter}',
        cached = _counts['${l.book}/${l.chapter}'];
    if (!refresh &&
        cached != null &&
        api.clock().difference(cached.at) < const Duration(minutes: 2)) {
      return cached.values[l.row] ?? 0;
    }
    final values = await _countRequests.putIfAbsent(key, () {
      final epoch = _countEpochs[key] ?? 0;
      late Future<Map<int, int>> task;
      task =
          (() async {
            final data = await api.request(
              '/argus/api/v1/chapterreview/getparagraphscommentcounts',
              {'bookId': l.book, 'chapterId': l.chapter},
            );
            _checkSession(session);
            if ((_countEpochs[key] ?? 0) != epoch) {
              throw const SourceException('起点段评已变化，请刷新计数');
            }
            // The App sets the requested chapter locally; this endpoint also
            // returns ChapterId=0 for valid chapter counts.
            if (data['ChapterId'] != null &&
                '${data['ChapterId']}' != '0' &&
                '${data['ChapterId']}' != l.chapter) {
              throw const SourceException('起点段评计数与章节不匹配');
            }
            final values = <int, int>{};
            for (final raw in _rows(data)) {
              final row = int.tryParse('${raw['ParagraphId']}');
              if (row == null || values.containsKey(row)) {
                throw const SourceException('起点段评计数段号无效或重复');
              }
              values[row] = _number(raw['CommentCount'], fallback: -1);
            }
            _counts[key] = (at: api.clock(), values: values);
            if (_counts.length > 128) _counts.remove(_counts.keys.first);
            return values;
          })().whenComplete(() {
            if (identical(_countRequests[key], task)) {
              _countRequests.remove(key);
            }
          });
      return task;
    });
    return values[l.row] ?? 0;
  }

  void _invalidateCounts(CommentLocation location) {
    final l = _location(location), key = '${l.book}/${l.chapter}';
    _counts.remove(key);
    _countRequests.remove(key);
    _countEpochs[key] = (_countEpochs[key] ?? 0) + 1;
  }

  Future<void> _publish(
    CommentLocation location,
    String text, {
    ParagraphComment? target,
  }) async {
    final l = _location(location), session = api.credentials;
    if (session == null) {
      throw const SourceException('请先在“我的 → 账号设置”登录起点读书后发送评论');
    }
    final content = text.trim();
    if (content.isEmpty) throw const SourceException('请输入评论内容');
    final quoteId = target == null ? null : _id(target.id);
    final quoteUser = target == null ? null : _id(target.authorId);
    final reference = target == null
        ? location.paragraph.text
        : _reviewContexts[target.id]?.quote ??
              commentContent(target.text).map((part) => part.text).join();
    final key = '${session.userId}/${l.book}/${l.chapter}/${l.row}';
    if (!_writes.add(key)) {
      throw const SourceException('此段落的评论正在发送，请等待完成');
    }
    const uncertain = SourceException('起点发送结果未确认，请先刷新列表检查，避免重复发送');
    try {
      // NewPublishCommentActivity + b2: text paragraph=2, root reply=10,
      // reply to a reply=13. quoteReviewId is the target's ID, not the root ID.
      // No dynamic feed sync, media, role, EPUB or automatic resubmission.
      final params = {
        'bookId': l.book,
        'chapterId': l.chapter,
        'paragraphId': '${l.row}',
        'content': content,
        if (reference.isNotEmpty) 'refferContent': reference,
        'type': target == null ? '2' : (target.isReply ? '13' : '10'),
        'quoteReviewId': ?quoteId,
        'quoteUserId': ?quoteUser,
        'isSyncDynamic': '0',
        'chapterSourceType': '0',
        'timeStamp': '0',
        'reCreationType': '0',
        'sessionKey': '',
        'banId': '0',
        'captchaTicket': '',
        'captchaRandStr': '',
        'challenge': '',
        'validate': '',
        'seccode': '',
      };
      late Map<String, dynamic> data;
      try {
        data = await api.request(
          '/argus/api/v2/chapterreview/addcomment',
          params,
          post: true,
        );
      } on SourceException catch (error) {
        if (error.code == 0 || error.code >= 500) throw uncertain;
        rethrow;
      } catch (_) {
        throw uncertain;
      }
      if (!identical(session, api.credentials)) {
        throw const SourceException('起点账号已切换，请在原账号下核实评论发送结果');
      }
      final risk = data['RiskConf'];
      if (risk != null) {
        if (risk is! Map) throw uncertain;
        final ban = int.tryParse('${risk['BanId'] ?? 0}');
        if (ban == null) throw uncertain;
        if (ban != 0) {
          throw SourceException(
            ban == 1
                ? '起点账号暂不能发表评论，请在官方 App 查看账号限制'
                : '起点要求安全验证，请在官方 App 完成验证后手动发送',
          );
        }
      }
      if (!RegExp(r'^[1-9]\d{0,18}$').hasMatch('${data['Id']}')) {
        throw uncertain;
      }
    } finally {
      _writes.remove(key);
      _invalidateCounts(location);
    }
  }

  @override
  Future<void> publishComment(CommentLocation location, String text) =>
      _publish(location, text);

  @override
  Future<void> postReply(
    ParagraphComment root,
    String text, {
    ParagraphComment? target,
    CommentLocation? location,
  }) async {
    if (location == null) throw const SourceException('起点回复缺少段落信息');
    if (root.isReply) throw const SourceException('请从起点主段评发送回复');
    _id(root.id);
    if (target != null && !target.isReply && target.id != root.id) {
      throw const SourceException('起点回复目标与主段评不匹配');
    }
    final l = _location(location), key = '${l.book}/${l.chapter}/${l.row}';
    for (final comment in [root, ?target]) {
      final context = _reviewContexts[comment.id];
      if (context != null &&
          (context.location != key || context.root != root.id)) {
        throw const SourceException('起点回复目标与段落或主段评不匹配');
      }
    }
    await _publish(location, text, target: target ?? root);
  }

  void _rememberReview(Map raw, String location) {
    final id = _id(raw['Id']);
    final meaning = '${raw['ImageMeaning'] ?? ''}';
    _reviewContexts[id] = (
      location: location,
      root: '${raw['ReviewType']}' == '2' ? _id(raw['RootReviewId']) : id,
      quote: '${meaning.isEmpty ? '' : '[$meaning]'}${raw['Content'] ?? ''}',
    );
    if (_reviewContexts.length > 2048) {
      _reviewContexts.remove(_reviewContexts.keys.first);
    }
  }

  static List<Map> _rows(Map data) {
    final rows = data['DataList'];
    if (rows is! List || rows.any((row) => row is! Map)) {
      throw const SourceException('起点段评列表格式已变化');
    }
    return rows.cast<Map>();
  }

  static void _checkLocation(Map raw, String book, String chapter, int row) {
    if (raw['BookId'] != null && '${raw['BookId']}' != book ||
        raw['ChapterId'] != null && '${raw['ChapterId']}' != chapter ||
        raw['ParagraphId'] != null && '${raw['ParagraphId']}' != '$row') {
      throw const SourceException('起点返回的段评与作品、章节或段落不匹配');
    }
  }

  ParagraphComment _comment(
    Map raw, {
    List<ParagraphComment> replies = const [],
  }) {
    final milliseconds = _number(raw['CreateTime']);
    if (milliseconds > 8640000000000000) {
      throw const SourceException('起点段评时间无效');
    }
    var text = '${raw['Content'] ?? ''}';
    final image =
        commentImageAddress('${raw['ImageDetail'] ?? ''}') ??
        commentImageAddress('${raw['PreImage'] ?? ''}');
    if (text.isEmpty && '${raw['AudioUrl'] ?? ''}'.isNotEmpty) {
      text = '［语音评论，请在起点官方 App 收听］';
    }
    final relatedUser = '${raw['RelatedUser'] ?? ''}';
    if (relatedUser.isNotEmpty && '${raw['ReviewType']}' == '2') {
      text = '回复 $relatedUser：$text';
    }
    if (image != null) {
      text = '\u0000qidian:${jsonEncode({'text': text, 'image': image})}';
    }
    return ParagraphComment(
      id: _id(raw['Id']),
      author: '${raw['UserName'] ?? '读者'}',
      authorId: '${raw['UserId'] ?? ''}',
      avatar: '${raw['UserHeadIcon'] ?? ''}',
      text: text,
      likes: _number(raw['AgreeAmount']),
      replyCount: _number(raw['ReviewCount']),
      paragraphText: '${raw['RefferContent'] ?? ''}',
      date: milliseconds == 0
          ? ''
          : DateTime.fromMillisecondsSinceEpoch(
              milliseconds,
              isUtc: true,
            ).toIso8601String(),
      isReply: '${raw['ReviewType']}' == '2',
      replies: orderedReplies(replies),
    );
  }

  @override
  List<CommentPart> commentContent(String text) {
    if (!text.startsWith('\u0000qidian:')) return [CommentPart.text(text)];
    try {
      final data = jsonDecode(text.substring('\u0000qidian:'.length)) as Map;
      final image = commentImageAddress('${data['image'] ?? ''}');
      return [
        CommentPart.text('${data['text'] ?? ''}'),
        if (image != null) CommentPart.image(image),
      ];
    } catch (_) {
      return [CommentPart.text(text)];
    }
  }

  @override
  Future<CommentPage> commentPage(
    CommentLocation location, {
    String? cursor,
    CommentSort sort = CommentSort.latest,
  }) async {
    final l = _location(location), session = api.credentials;
    final key = '${l.book}/${l.chapter}/${l.row}/${sort.name}';
    final paging = _ReviewPaging.parse(cursor, key);
    final data = await api
        .request('/argus/api/v2/chapterreview/getparagraphscomments', {
          'bookId': l.book,
          'chapterId': l.chapter,
          'paragraphId': '${l.row}',
          'pg': '${paging.page}',
          'pz': '10',
          'type': sort == CommentSort.hot ? '100' : '101',
          'anchorId': '0',
          'from': '0',
          if (paging.token != null) 'nextCursor': paging.token!,
        });
    _checkSession(session);
    if (data['BookInfo'] case final Map info) {
      _checkLocation(info, l.book, l.chapter, l.row);
    }
    final rows = _rows(data), roots = <String, Map>{};
    final replies = <String, Map<String, ParagraphComment>>{};
    for (final raw in rows) {
      final type = _number(raw['ReviewType'], fallback: -1);
      // DataList also carries fold/load-more/count/advertising rows.
      if (type != 1 && type != 2) continue;
      _checkLocation(raw, l.book, l.chapter, l.row);
      final comment = _comment(raw);
      _rememberReview(raw, '${l.book}/${l.chapter}/${l.row}');
      if (type == 1) {
        roots[comment.id] = raw;
      } else {
        (replies[_id(raw['RootReviewId'])] ??= {})[comment.id] = comment;
      }
    }
    return CommentPage([
      for (final entry in roots.entries)
        _comment(
          entry.value,
          replies: replies[entry.key]?.values.toList() ?? [],
        ),
    ], nextCursor: paging.next(data, rows.length >= 10, key));
  }

  @override
  Future<List<ParagraphComment>> repliesFor(
    CommentLocation location,
    ParagraphComment root, {
    bool Function()? cancelled,
  }) async {
    final l = _location(location), session = api.credentials, id = _id(root.id);
    if (root.isReply) throw const SourceException('请从起点主段评打开回复');
    final items = <String, ParagraphComment>{}, seen = <String>{};
    var page = 1, size = 20;
    int? mode;
    String? token;
    for (var attempt = 0; attempt < 100; attempt++) {
      if (cancelled?.call() == true) return orderedReplies(items.values);
      final data = await api
          .request('/argus/api/v2/chapterreview/getparagraphscommentsreview', {
            'bookId': l.book,
            'chapterId': l.chapter,
            'paragraphId': '${l.row}',
            'pg': '$page',
            'pz': '$size',
            'rootReviewId': id,
            'type': '0',
            'scene': '0',
            'nextCursor': ?token,
          });
      _checkSession(session);
      if (cancelled?.call() == true) return orderedReplies(items.values);
      final rows = _rows(data);
      final responseMode = _ReviewPaging.modeOf(data);
      if (mode != null && responseMode != mode) {
        throw const SourceException('起点回复分页协议已变化，请刷新');
      }
      mode = responseMode;
      Map? more;
      for (final raw in rows) {
        if ('${raw['ReviewType']}' == '4') {
          more = raw;
          continue;
        }
        if ('${raw['ReviewType']}' != '2') continue;
        _checkLocation(raw, l.book, l.chapter, l.row);
        if ('${raw['RootReviewId']}' != id) {
          throw const SourceException('起点回复与主段评不匹配');
        }
        final item = _comment(raw);
        _rememberReview(raw, '${l.book}/${l.chapter}/${l.row}');
        items[item.id] = item;
      }
      if (more == null) return orderedReplies(items.values);
      if ('${more['RootReviewId']}' != id) {
        throw const SourceException('起点回复分页与主段评不匹配');
      }
      if (mode == 1) {
        final next = '${more['NextCursor'] ?? data['NextCursor'] ?? ''}';
        if (next == 'emptyCursor') return orderedReplies(items.values);
        if (next.isEmpty || next == token || !seen.add(next)) {
          throw const SourceException('起点回复分页游标未推进');
        }
        token = next;
        page = 1;
      } else {
        final nextPage = _number(more['PageIndex'], fallback: -1);
        size = _number(more['PageSize'], fallback: -1);
        if (nextPage <= page || size < 1 || size > 100) {
          throw const SourceException('起点回复分页未推进');
        }
        page = nextPage;
      }
    }
    throw const SourceException('此段评回复过多，请在起点官方 App 查看更多回复');
  }
}

class _ReviewPaging {
  const _ReviewPaging({this.page = 1, this.mode, this.token});
  final int page;
  final int? mode;
  final String? token;

  static _ReviewPaging parse(String? cursor, String key) {
    if (cursor == null) return const _ReviewPaging();
    try {
      final data = jsonDecode(cursor) as Map;
      final page = data['page'] as int, mode = data['mode'] as int;
      final token = data['token'] as String?;
      if (data['key'] != key ||
          page < 1 ||
          page > 10000 ||
          !{0, 1}.contains(mode) ||
          mode == 1 &&
              (page != 1 ||
                  token == null ||
                  token.isEmpty ||
                  token == 'emptyCursor') ||
          mode == 0 && token != null) {
        throw const FormatException();
      }
      return _ReviewPaging(page: page, mode: mode, token: token);
    } catch (_) {
      throw const SourceException('起点段评分页无效，请刷新列表');
    }
  }

  static int modeOf(Map data) {
    final mode = data['PagingMode'] ?? 0;
    if (mode != 0 && mode != 1) {
      throw const SourceException('起点段评分页协议无法识别');
    }
    return mode as int;
  }

  String? next(Map data, bool full, String key) {
    final responseMode = modeOf(data);
    if (mode != null && responseMode != mode) {
      throw const SourceException('起点段评分页协议已变化，请刷新列表');
    }
    String? nextToken;
    if (responseMode == 1) {
      nextToken = '${data['NextCursor'] ?? ''}';
      if (nextToken == 'emptyCursor') return null;
      if (nextToken.isEmpty || nextToken == token) {
        throw const SourceException('起点段评分页游标未推进');
      }
    } else if (!full) {
      return null;
    }
    return jsonEncode({
      'key': key,
      'page': responseMode == 1 ? 1 : page + 1,
      'mode': responseMode,
      'token': nextToken,
    });
  }
}
