import 'dart:convert';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import '../../domain/models.dart';
import '../novel_source.dart';
import 'sfacg_api.dart';
import 'sfacg_markup.dart';
import '../comment_source.dart';

export '../comment_source.dart' show CommentSort;

class SfacgSource extends CommentSource implements SearchableNovelSource {
  SfacgSource(this.api, {Map<String, String>? cipher}) : cipher = cipher ?? {};
  final SfacgApi api;
  final Map<String, String> cipher;
  final Map<String, ({DateTime at, int count})> _commentCounts = {};
  final Map<String, Future<int>> _countRequests = {};
  final Map<String, int> _countEpochs = {};
  final Map<String, ValueNotifier<CommentLikeStatus>> _likes = {};
  final Map<String, Future<void>> _likeRequests = {};
  final Map<String, int> _likeVersions = {};
  int _likeEpoch = 0;
  @override
  String get id => 'sfacg';
  @override
  String get name => '菠萝包轻小说';
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
    sorts: {CommentSort.hot, CommentSort.latest},
  );
  @override
  String? avatarAddress(String address) => SfacgMarkup.imageAddress(address);
  @override
  List<CommentPart> commentContent(String text) {
    final parts = <CommentPart>[];
    var start = 0;
    for (final tag in SfacgMarkup.tags.allMatches(text)) {
      parts.add(CommentPart.text(text.substring(start, tag.start)));
      final image = SfacgMarkup.imageUrl(tag);
      parts.add(
        image == null
            ? CommentPart.text(tag[0]!)
            : CommentPart.image(image, text: tag[0]!),
      );
      start = tag.end;
    }
    parts.add(CommentPart.text(text.substring(start)));
    return parts;
  }

  @override
  List<ParagraphComment> orderedReplies(Iterable<ParagraphComment> comments) =>
      oldestFirst(comments);

  static String bookId(String input) {
    final value = input.trim();
    if (RegExp(r'^\d{1,10}$').hasMatch(value)) return value;
    final uri = Uri.tryParse(value);
    if (uri != null &&
        ['https', 'http'].contains(uri.scheme) &&
        ['book.sfacg.com', 'm.sfacg.com'].contains(uri.host.toLowerCase())) {
      final match = RegExp(
        r'^/(?:Novel|b|i)/(\d{1,10})(?:/|$)',
        caseSensitive: false,
      ).firstMatch(uri.path);
      if (match != null) return match[1]!;
    }
    throw const SourceException('请输入小说 ID 或菠萝包作品链接');
  }

  @override
  Future<List<Book>> search(String keyword, {int page = 0}) async {
    if (keyword.trim().isEmpty) return [];
    final data = await api.get(
      'search/novels/result/new',
      query: {'q': keyword.trim(), 'page': '$page', 'size': '20'},
    );
    return ((data as Map)['novels'] as List? ?? [])
        .map(
          (j) => Book(
            id: '${j['novelId']}',
            title: j['novelName'] ?? '',
            author: j['authorName'] ?? '',
            cover: j['novelCover'] ?? '',
            updatedAt: _updateTime(j['lastUpdateTime']),
            chapters: [],
          ),
        )
        .toList();
  }

  @override
  Future<Book> getBook(String input) async {
    final id = bookId(input);
    final info =
        await api.get('novels/$id', query: {'expand': 'bigNovelCover,intro'})
            as Map;
    final dirs =
        await api.get(
              'novels/$id/dirs',
              query: {'expand': 'originNeedFireMoney'},
            )
            as Map;
    final chapters = <Chapter>[];
    final seen = <String>{};
    for (final v in (dirs['volumeList'] as List? ?? [])) {
      for (final c in (v['chapterList'] as List? ?? [])) {
        final cid = '${c['chapId']}';
        if (!RegExp(r'^\d+$').hasMatch(cid) || cid == '0' || !seen.add(cid)) {
          throw const SourceException('菠萝包目录包含无效或重复章节');
        }
        final vip =
            c['isVip'] == true || (c['originNeedFireMoney'] as num? ?? 0) > 0;
        chapters.add(
          Chapter(
            id: cid,
            title: c['title'] ?? cid,
            volume: '${v['title'] ?? '正文'}',
            vip: vip,
            url: vip
                ? 'https://book.sfacg.com/vip/c/$cid/'
                : 'https://book.sfacg.com/Novel/$id/${v['volumeId']}/$cid/',
          ),
        );
      }
    }
    if (chapters.isEmpty) throw const SourceException('作品没有可读取的章节目录');
    return Book(
      id: id,
      title: info['novelName'] ?? id,
      author: info['authorName'] ?? '',
      cover: info['novelCover'] ?? '',
      description: info['expand']?['intro'] ?? '',
      updatedAt:
          _updateTime(dirs['lastUpdateTime']) ??
          _updateTime(info['lastUpdateTime']),
      chapters: chapters,
    );
  }

  static DateTime? _updateTime(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    final value = raw.trim();
    // SFACG's offset-free timestamps use China Standard Time, independently of
    // the reader device's timezone.
    final hasZone = RegExp(r'(?:[zZ]|[+-]\d{2}:?\d{2})$').hasMatch(value);
    return DateTime.tryParse(hasZone ? value : '$value+08:00')?.toUtc();
  }

  @override
  Future<ChapterContent> readChapter(Book book, Chapter chapter) async {
    if (!chapter.vip) {
      final response = await api.client
          .get(
            Uri.parse(chapter.url),
            headers: {
              'User-Agent': 'Mozilla/5.0',
              'Referer': 'https://book.sfacg.com/',
            },
          )
          .timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw SourceException('官网章节暂时无法访问（HTTP ${response.statusCode}）');
      }
      return parsePublicChapter(utf8.decode(response.bodyBytes));
    }
    if (!api.hasSession) throw const SourceException('此章节需要在“我的 → 账号设置”中登录菠萝包');
    final data =
        await api.get(
              'Chaps/${chapter.id}',
              query: {'expand': 'content,expand.content', 'autoOrder': 'false'},
            )
            as Map;
    final raw = '${data['content'] ?? ''}${data['expand']?['content'] ?? ''}';
    if (raw.trim().isEmpty) throw const SourceException('未取得正文，请检查已有章节阅读权限');
    if (cipher.length != 3751) throw const SourceException('菠萝包正文字符表不完整');
    return parseAppContent(decode(raw));
  }

  String decode(String raw) {
    // Image URLs must never be passed through the Han character substitution.
    final image = RegExp(
      r'\[img[^\]]*\](?:[^\[]*\[/img\])?',
      caseSensitive: false,
    );
    final out = StringBuffer();
    var start = 0;
    for (final m in image.allMatches(raw)) {
      out.write(_decodeText(raw.substring(start, m.start)));
      out.write(m[0]);
      start = m.end;
    }
    out.write(_decodeText(raw.substring(start)));
    return out.toString();
  }

  String _decodeText(String value) => value.runes.map((r) {
    final s = String.fromCharCode(r);
    return cipher[s] ?? s;
  }).join();

  static ChapterContent parsePublicChapter(String value) {
    final body = html.parse(value).querySelector('#ChapterBody');
    if (body == null) throw const SourceException('官网未返回完整正文');
    final paragraphs = <Paragraph>[];
    var row = 0;
    final text = StringBuffer();
    void flush(int? currentRow) {
      final value = text.toString().trim();
      text.clear();
      if (value.isNotEmpty) {
        paragraphs.add(Paragraph(value, remoteIndex: currentRow));
      }
    }

    void visit(Node node, int? currentRow) {
      if (node is Text) {
        text.write(node.text);
        return;
      }
      if (node is! Element || ['script', 'style'].contains(node.localName)) {
        return;
      }
      if (node.localName == 'p') {
        flush(currentRow);
        // Empty paragraphs still occupy a row in the official App.
        final paragraphRow = ++row;
        for (final child in node.nodes) {
          visit(child, paragraphRow);
        }
        flush(paragraphRow);
        return;
      }
      if (node.localName == 'img') {
        flush(currentRow);
        final src = node.attributes['data-src'] ?? node.attributes['src'];
        if (src != null && src.trim().isNotEmpty) {
          paragraphs.add(
            Paragraph(
              '',
              image: Uri.parse(
                'https://book.sfacg.com/',
              ).resolve(src.trim()).toString(),
              remoteIndex: currentRow,
            ),
          );
        }
        return;
      }
      if (node.localName == 'br') {
        flush(currentRow);
        return;
      }
      for (final child in node.nodes) {
        visit(child, currentRow);
      }
    }

    visit(body, null);
    flush(null);
    if (paragraphs.isEmpty) throw const SourceException('官网未返回可阅读正文');
    return ChapterContent(paragraphs);
  }

  static ChapterContent parseAppContent(String value) {
    final paragraphs = <Paragraph>[];
    final normalized = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final newlines = RegExp(
      '\n',
    ).allMatches(normalized).map((m) => m.start).toList();
    int rowAt(int offset) {
      var low = 0, high = newlines.length;
      while (low < high) {
        final mid = (low + high) ~/ 2;
        if (newlines[mid] < offset) {
          low = mid + 1;
        } else {
          high = mid;
        }
      }
      return low + 1;
    }

    void appendText(int start, int end) {
      final part = normalized.substring(start, end);
      for (final line in RegExp(r'[^\n]+').allMatches(part)) {
        final text = line[0]!.trim();
        if (text.isNotEmpty) {
          paragraphs.add(
            Paragraph(text, remoteIndex: rowAt(start + line.start)),
          );
        }
      }
    }

    final images = RegExp(
      r'\[img\s*=\s*\d+\s*,\s*\d+\s*\]\s*([^\[\]\r\n]+?)\s*\[/img\s*\]|\[img\s*\]\s*([^\[\]\r\n]+?)\s*\[/img\s*\]|\[img\s*=\s*([^\]\r\n]+)\](?:\s*\[/img\s*\])?',
      caseSensitive: false,
    );
    var start = 0;
    for (final image in images.allMatches(normalized)) {
      appendText(start, image.start);
      paragraphs.add(
        Paragraph(
          '',
          image: (image[1] ?? image[2] ?? image[3])!.trim(),
          remoteIndex: rowAt(image.start),
        ),
      );
      start = image.end;
    }
    appendText(start, normalized.length);
    if (paragraphs.isEmpty) throw const SourceException('未取得可阅读正文');
    return ChapterContent(paragraphs);
  }

  Future<List<ParagraphComment>> comments(
    Chapter chapter,
    int paragraph, {
    int page = 0,
    CommentSort sort = CommentSort.hot,
  }) async {
    if (paragraph < 1 || page < 0) throw ArgumentError('段落从 1 开始，分页从 0 开始');
    final snapshot = _likeEpoch;
    final data = await api.get(
      'chaps/0/${chapter.id}/tsukkomis',
      query: {
        'row': '$paragraph',
        'page': '$page',
        'size': '20',
        'sort': sort == CommentSort.hot ? 'hot' : 'date',
        'expand':
            'avatar,chapterTitle,chapterContent,replys,avatarFrame,favNum',
      },
    );
    if (data is! List) throw const SourceException('菠萝包段评数据格式已变化');
    final comments = data
        .map((j) => parseComment(Map<String, dynamic>.from(j)))
        .toList();
    for (final comment in comments) {
      final key = _likeKey(comment);
      final state = _likes[key];
      if (state != null &&
          !state.value.sending &&
          (_likeVersions[key] ?? 0) <= snapshot) {
        state.value = CommentLikeStatus(
          count: comment.likes,
          liked: state.value.liked,
        );
      }
    }
    return comments;
  }

  @override
  Future<CommentPage> commentPage(
    CommentLocation location, {
    String? cursor,
    CommentSort sort = CommentSort.latest,
  }) async {
    final page = cursor == null ? 0 : int.parse(cursor);
    final items = await comments(
      location.chapter,
      location.paragraph.remoteIndex ?? 0,
      page: page,
      sort: sort,
    );
    return CommentPage(
      items,
      nextCursor: items.length == 20 ? '${page + 1}' : null,
    );
  }

  @override
  Future<int> paragraphCommentCount(
    CommentLocation location, {
    bool refresh = false,
  }) => commentCount(
    location.chapter,
    location.paragraph.remoteIndex ?? 0,
    refresh: refresh,
  );
  @override
  Future<List<ParagraphComment>> repliesFor(
    CommentLocation location,
    ParagraphComment root, {
    bool Function()? cancelled,
  }) => allReplies(root.id, cancelled: cancelled);
  @override
  Future<void> publishComment(CommentLocation location, String text) =>
      postComment(location.chapter, location.paragraph.remoteIndex ?? 0, text);

  String _likeKey(ParagraphComment comment) {
    final session = sha256.convert(
      utf8.encode(
        '${api.cookies['.SFCommunity'] ?? ''}\n${api.cookies['session_APP'] ?? ''}',
      ),
    );
    return '$session/${comment.isReply ? 'reply' : 'comment'}/${comment.id}';
  }

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
    final state = likeStatus(comment);
    String? invalid;
    if (!api.hasSession) {
      invalid = '请先在“我的 → 账号设置”中登录菠萝包后点赞';
    } else if (comment.isReply || !RegExp(r'^\d+$').hasMatch(comment.id)) {
      invalid = '当前评论不支持点赞';
    }
    if (invalid != null) {
      state.value = CommentLikeStatus(
        count: state.value.count,
        message: invalid,
      );
      return Future.error(SourceException(invalid));
    }
    if (state.value.liked) return Future.value();
    final key = _likeKey(comment);
    return _likeRequests.putIfAbsent(
      key,
      () => _likeComment(comment, state).whenComplete(() {
        _likeRequests.remove(key);
      }),
    );
  }

  Future<void> _likeComment(
    ParagraphComment comment,
    ValueNotifier<CommentLikeStatus> state,
  ) async {
    final key = _likeKey(comment);
    _likeVersions[key] = ++_likeEpoch;
    final before = state.value.count;
    state.value = CommentLikeStatus(count: before, sending: true);
    dynamic result;
    try {
      result = await api.request(
        'tsukkomis/0/${comment.id}/favs',
        method: 'POST',
        retry: false,
      );
    } catch (e) {
      final uncertain =
          e is TimeoutException ||
          e is http.ClientException ||
          e is SourceException &&
              (e.code >= 500 || e.message.startsWith('菠萝包返回无法识别的数据'));
      final message = uncertain ? '点赞结果未确认，请先刷新评论检查，再决定是否重试' : '$e';
      _likeVersions[key] = ++_likeEpoch;
      state.value = CommentLikeStatus(count: before, message: message);
      throw SourceException(message);
    }
    // The POST acknowledges a like, not necessarily a new like. Read the
    // server's count instead of blindly adding one after an idempotent response.
    try {
      if (result is! Map || result['favNum'] is! int) {
        result = await api.get(
          'tsukkomis/0/${comment.id}',
          query: {'expand': 'favNum'},
        );
      }
      final count = result is Map ? result['favNum'] : null;
      if (count is! int || count < 0) throw const SourceException('未取得点赞数量');
      _likeVersions[key] = ++_likeEpoch;
      state.value = CommentLikeStatus(count: count, liked: true);
    } catch (_) {
      _likeVersions[key] = ++_likeEpoch;
      state.value = CommentLikeStatus(
        count: before,
        liked: true,
        message: '已点赞，赞数暂未更新，请刷新评论列表',
      );
    }
  }

  Future<List<ParagraphComment>> replies(
    String commentId, {
    int page = 0,
  }) async {
    final data = await api.get(
      'tsukkomis/0/$commentId/replys',
      query: {'page': '$page', 'size': '20', 'expand': 'avatar'},
    );
    if (data is! List) throw const SourceException('菠萝包回复数据格式已变化');
    return data
        .map((j) => parseComment(Map<String, dynamic>.from(j), reply: true))
        .toList();
  }

  Future<void> postComment(Chapter chapter, int row, String text) async {
    if (!api.hasSession) {
      throw const SourceException('请先在“我的 → 账号设置”中登录菠萝包后发表评论');
    }
    if (row < 1 || !RegExp(r'^\d+$').hasMatch(chapter.id)) {
      throw const SourceException('当前段落信息无效，无法发送段评');
    }
    final content = text.trim();
    if (content.isEmpty) throw const SourceException('请输入评论内容');
    const uncertain = SourceException('发送结果未确认，请先刷新段评检查是否已发布，再决定是否重试');
    try {
      await api.request(
        'chaps/0/${chapter.id}/tsukkomis',
        body: {'content': content, 'row': row},
        retry: false,
      );
    } on TimeoutException {
      throw uncertain;
    } on http.ClientException {
      throw uncertain;
    } on SourceException catch (e) {
      if (e.code >= 500 || e.message.startsWith('菠萝包返回无法识别的数据')) {
        throw uncertain;
      }
      rethrow;
    } finally {
      // A response can be lost after the server accepted a write.
      final key = '${chapter.id}/$row';
      _commentCounts.remove(key);
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
    if (!api.hasSession) {
      throw const SourceException('请先在“我的 → 账号设置”中登录菠萝包后回复评论');
    }
    // This endpoint accepts a root tsukkomiId, never a replyId.
    if (root.isReply || !RegExp(r'^[1-9]\d*$').hasMatch(root.id)) {
      throw const SourceException('原段评信息无效，无法发送回复');
    }
    final draft = text.trim();
    if (draft.isEmpty) throw const SourceException('请输入回复内容');
    // SFACG targets a root tsukkomi; replies within it use a visible mention.
    final content = target?.isReply == true
        ? '回复@${target!.author} $draft'
        : draft;
    const uncertain = SourceException('发送结果未确认，请先刷新回复检查是否已发布，再决定是否重试');
    try {
      await api.request(
        'tsukkomis/0/${root.id}/replys',
        body: {'content': content},
        retry: false,
      );
    } on TimeoutException {
      throw uncertain;
    } on http.ClientException {
      throw uncertain;
    } on SourceException catch (e) {
      if (e.code >= 500 || e.message.startsWith('菠萝包返回无法识别的数据')) {
        throw uncertain;
      }
      rethrow;
    }
  }

  Future<int> commentCount(Chapter chapter, int row, {bool refresh = false}) {
    if (row < 1) throw ArgumentError('段落从 1 开始');
    final key = '${chapter.id}/$row';
    final cached = _commentCounts[key];
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 2)) {
      return Future.value(cached.count);
    }
    final epoch = _countEpochs[key] ?? 0;
    final requestKey = '$key:$epoch';
    return _countRequests.putIfAbsent(requestKey, () async {
      try {
        final headers =
            await api.request(
                  'chaps/0/${chapter.id}/tsukkomis',
                  head: true,
                  query: {'row': '$row'},
                )
                as Map<String, String>;
        final count = int.tryParse(headers['x-total-count'] ?? '');
        if (count == null || count < 0) {
          throw const SourceException('菠萝包未返回段评数量');
        }
        if ((_countEpochs[key] ?? 0) == epoch) {
          _commentCounts[key] = (at: DateTime.now(), count: count);
        }
        if (_commentCounts.length > 500) {
          _commentCounts.remove(_commentCounts.keys.first);
        }
        return count;
      } finally {
        _countRequests.remove(requestKey);
      }
    });
  }

  // Fetch every server page before displaying a chronological conversation.
  // Sorting only the first (newest) page would put old replies after new ones.
  Future<List<ParagraphComment>> allReplies(
    String commentId, {
    bool Function()? cancelled,
  }) async {
    final found = <String, ParagraphComment>{};
    for (var page = 0; ; page++) {
      if (cancelled?.call() == true) return [];
      final batch = await replies(commentId, page: page);
      final before = found.length;
      for (final reply in batch) {
        found[reply.id] = reply;
      }
      if (batch.length < 20) break;
      if (before == found.length) {
        throw const SourceException('回复分页重复，请重试');
      }
    }
    return oldestFirst(found.values);
  }

  static List<ParagraphComment> oldestFirst(
    Iterable<ParagraphComment> replies,
  ) {
    final ordered = replies.toList();
    ordered.sort((a, b) {
      final first = DateTime.tryParse(a.date),
          second = DateTime.tryParse(b.date);
      if (first != null && second != null) {
        final byDate = first.compareTo(second);
        if (byDate != 0) return byDate;
      }
      final firstId = int.tryParse(a.id), secondId = int.tryParse(b.id);
      return firstId != null && secondId != null
          ? firstId.compareTo(secondId)
          : a.id.compareTo(b.id);
    });
    return ordered;
  }

  static ParagraphComment parseComment(
    Map<String, dynamic> j, {
    bool reply = false,
  }) {
    final user = (j[reply ? 'replyUser' : 'postUser'] as Map?) ?? {};
    final expand = (j['expand'] as Map?) ?? {};
    return ParagraphComment(
      id: '${j[reply ? 'replyId' : 'tsukkomiId']}',
      author: user['nickName'] ?? user['userName'] ?? '读者',
      authorId: '${user['accountId'] ?? user['userId'] ?? ''}',
      text: j['content'] ?? '',
      likes: j['favNum'] as int? ?? 0,
      replyCount: j['replyNum'] as int? ?? 0,
      date: j[reply ? 'replyDate' : 'postDate'] ?? '',
      paragraphText: expand['chapterContent'] ?? '',
      avatar:
          '${user['expand']?['avatar'] ?? expand['avatar'] ?? user['avatar'] ?? ''}',
      replies: ((expand['replys'] as List?) ?? [])
          .map((r) => parseComment(Map<String, dynamic>.from(r), reply: true))
          .toList(),
      isReply: reply,
    );
  }
}
