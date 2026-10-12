import 'dart:convert';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import '../domain/models.dart';
import 'novel_source.dart';
import 'sfacg_api.dart';

enum CommentSort { hot, latest }

class SfacgSource implements NovelSource {
  SfacgSource(this.api, {Map<String, String>? cipher}) : cipher = cipher ?? {};
  final SfacgApi api;
  final Map<String, String> cipher;
  final Map<String, ({DateTime at, int count})> _commentCounts = {};
  final Map<String, Future<int>> _countRequests = {};
  @override
  String get id => 'sfacg';
  @override
  String get name => '菠萝包轻小说';

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
      chapters: chapters,
    );
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
    if (!api.hasSession) throw const SourceException('此章节需要在账号设置中登录菠萝包');
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

  @override
  Future<List<ParagraphComment>> comments(
    Chapter chapter,
    int paragraph, {
    int page = 0,
    CommentSort sort = CommentSort.hot,
  }) async {
    if (paragraph < 1 || page < 0) throw ArgumentError('段落从 1 开始，分页从 0 开始');
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
    return data.map((j) => parseComment(Map<String, dynamic>.from(j))).toList();
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

  Future<int> commentCount(Chapter chapter, int row, {bool refresh = false}) {
    if (row < 1) throw ArgumentError('段落从 1 开始');
    final key = '${chapter.id}/$row';
    final cached = _commentCounts[key];
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 2)) {
      return Future.value(cached.count);
    }
    return _countRequests.putIfAbsent(key, () async {
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
        _commentCounts[key] = (at: DateTime.now(), count: count);
        if (_commentCounts.length > 500) {
          _commentCounts.remove(_commentCounts.keys.first);
        }
        return count;
      } finally {
        _countRequests.remove(key);
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
    );
  }
}
