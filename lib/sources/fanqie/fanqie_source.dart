import 'dart:convert';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import '../../domain/models.dart';
import '../novel_source.dart';
import '../bookshelf_source.dart';
import 'fanqie_comments.dart';

class FanqieSource extends FanqieComments
    implements SearchableNovelSource, BookshelfSource {
  FanqieSource(super.api, {Map<String, String>? cipher})
    : cipher = cipher ?? {};
  final Map<String, String> cipher;
  @override
  String get id => 'fanqie';
  @override
  String get name => '番茄小说';
  @override
  Future<List<RemoteBookshelf>> getShelves() async {
    if (!hasSession) throw const SourceException('请先在“我的 → 账号设置”登录番茄小说');
    final result = <RemoteBookshelf>[
      const RemoteBookshelf(id: 'default', name: '默认书架'),
    ];
    var offset = 0;
    final seen = <String>{};
    for (var page = 0; page < 200; page++) {
      final data = await api.app.request(
        '/reading/distribution/bookshelf_folder/list/v1/',
        body: {
          'offset': offset,
          'count': 50,
          'has_detail': false,
          'preview_items_limit': 0,
        },
      );
      final folders = data['folders'];
      if (folders is! List) throw const SourceException('番茄书架列表格式已变化');
      for (final folder in folders) {
        if (folder is! Map) throw const SourceException('番茄书架列表格式已变化');
        final id = '${folder['folder_id']}';
        if (!RegExp(r'^[1-9]\d*$').hasMatch(id)) {
          throw const SourceException('番茄书架编号无效');
        }
        if (seen.add(id)) {
          result.add(
            RemoteBookshelf(
              id: id,
              name: '${folder['folder_name'] ?? '未命名书架'}',
            ),
          );
        }
      }
      if (data['has_more'] != true) return result;
      final next = int.tryParse('${data['next_offset']}');
      if (next == null || next <= offset) {
        throw const SourceException('番茄书架分页未前进，请重试');
      }
      offset = next;
    }
    throw const SourceException('番茄书架数量过多，未能完整获取');
  }

  @override
  Future<List<String>> getShelfBookIds(RemoteBookshelf shelf) async {
    if (!hasSession) throw const SourceException('请先登录番茄小说');
    if (shelf.id == 'default') {
      final data = await api.app.request('/reading/bookapi/bookshelf/info/v/');
      final list = data['book_shelf_info'] ?? data['book_list'];
      if (list is! List) throw const SourceException('番茄默认书架数据格式已变化');
      final ids = <String>{};
      for (final item in list) {
        if (item is Map) {
          if ('${item['book_type'] ?? 0}' != '0') continue;
          ids.add(bookId('${item['book_id']}'));
        } else {
          ids.add(bookId('$item'));
        }
      }
      return ids.toList();
    }
    if (!RegExp(r'^[1-9]\d*$').hasMatch(shelf.id)) {
      throw const SourceException('番茄书架编号无效');
    }
    var offset = 0;
    final ids = <String>{};
    for (var page = 0; page < 200; page++) {
      final data = await api.app.request(
        '/reading/distribution/bookshelf_folder/detail/v1/',
        body: {
          'folder_id': int.parse(shelf.id),
          'offset': offset,
          'limit': 50,
          'has_detail': false,
        },
      );
      final items = data['items'];
      if (items is! List) throw const SourceException('番茄书架作品列表格式已变化');
      for (final item in items) {
        if (item is! Map) throw const SourceException('番茄书架作品列表格式已变化');
        // ReadingBookType.Read = 0; audio, videos and posts are separate media.
        if ('${item['book_type'] ?? 0}' != '0') continue;
        ids.add(bookId('${item['item_id']}'));
      }
      if (data['has_more'] != true) return ids.toList();
      final next = int.tryParse('${data['next_offset']}');
      if (next == null || next <= offset) {
        throw const SourceException('番茄书架分页未前进，请重试');
      }
      offset = next;
    }
    throw const SourceException('番茄书架作品过多，未能完整获取');
  }

  static final _id = RegExp(r'^[1-9]\d{14,19}$');
  static const _hosts = {
    'fanqienovel.com',
    'www.fanqienovel.com',
    'reading.snssdk.com',
  };

  static Uri? _link(String input) {
    final match = RegExp(r'https?://[^\s<>「」“”]+').firstMatch(input);
    if (match == null) return null;
    final uri = Uri.tryParse(match[0]!.replaceAll(RegExp(r'[，。；）)]+$'), ''));
    if (uri == null ||
        !_hosts.contains(uri.host.toLowerCase()) ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort && uri.port != 443 && uri.port != 80) {
      return null;
    }
    return uri.replace(scheme: 'https');
  }

  static String bookId(String input) {
    final value = input.trim();
    if (_id.hasMatch(value)) return value;
    final uri = _link(value);
    if (uri != null) {
      final match = RegExp(r'^/page/([1-9]\d{14,19})/?$').firstMatch(uri.path);
      if (match != null && uri.host.endsWith('fanqienovel.com')) {
        return match[1]!;
      }
      for (final key in ['book_id', 'bookId', 'bookid']) {
        final candidate = uri.queryParameters[key];
        if (candidate != null && _id.hasMatch(candidate)) return candidate;
      }
    }
    throw const SourceException('请输入番茄作品 ID、官网作品链接或分享链接');
  }

  Future<String> _resolveId(String input) async {
    try {
      return bookId(input);
    } on SourceException {
      /* Resolve official short links. */
    }
    var uri = _link(input);
    if (uri == null || !uri.path.startsWith('/h5/')) return bookId(input);
    for (var i = 0; i < 4; i++) {
      final response = await api.fetch(uri!, redirect: false);
      if (response.statusCode >= 300) {
        final location = response.headers['location'];
        if (location == null) break;
        final next = _link(uri.resolve(location).toString());
        if (next == null) throw const SourceException('番茄分享链接跳转地址无效');
        try {
          return bookId(next.toString());
        } on SourceException {
          /* Follow next redirect. */
        }
        uri = next;
      } else {
        final page = initialState(utf8.decode(response.bodyBytes))['page'];
        if (page is Map && _id.hasMatch('${page['bookId']}')) {
          return '${page['bookId']}';
        }
        break;
      }
    }
    throw const SourceException('无法解析番茄分享链接，请使用官网作品链接或作品 ID');
  }

  @override
  Future<List<Book>> search(String keyword, {int page = 0}) async {
    if (keyword.trim().isEmpty) return [];
    if (page < 0) throw const SourceException('搜索页码无效');
    final data = await api.search(keyword.trim(), page: page);
    final list = data['ret_data'];
    if (list is! List) throw const SourceException('番茄搜索结果格式已变化');
    final infos = list.map((raw) {
      if (raw is! Map) throw const SourceException('番茄搜索结果格式已变化');
      final info = raw['book_data'] is Map ? raw['book_data'] as Map : raw;
      final bid = '${info['book_id'] ?? info['bookId'] ?? ''}';
      if (!_id.hasMatch(bid)) throw const SourceException('番茄搜索结果包含无效作品 ID');
      return info;
    }).toList();
    final favorites = <String, int>{};
    try {
      for (var offset = 0; offset < infos.length; offset += 20) {
        favorites.addAll(
          await api.app.bookFavoriteCounts(
            infos
                .skip(offset)
                .take(20)
                .map((info) => '${info['book_id'] ?? info['bookId']}'),
          ),
        );
      }
    } on SourceException {
      // A missing popularity response must not discard successful search results.
    }
    return infos.map((info) {
      final bid = '${info['book_id'] ?? info['bookId']}';
      return Book(
        id: bid,
        source: id,
        title:
            html
                .parseFragment('${info['title'] ?? info['book_name'] ?? bid}')
                .text ??
            bid,
        author: '${info['author'] ?? info['author_name'] ?? ''}',
        cover: '${info['audio_thumb_uri'] ?? info['thumb_url'] ?? ''}'
            .replaceFirst(RegExp(r'^//'), 'https://'),
        description: html.parseFragment('${info['abstract'] ?? ''}').text ?? '',
        favoriteCount: favorites[bid],
        wordCount: Book.parseWordCount(info['word_number']),
        chapters: [],
      );
    }).toList();
  }

  @override
  Future<Book> getBook(String input) async {
    final bid = await _resolveId(input);
    final response = await api.fetch(
      Uri.https('fanqienovel.com', '/page/$bid'),
    );
    final state = initialState(utf8.decode(response.bodyBytes));
    final info = state['page'];
    if (info is! Map ||
        '${info['bookId']}' != bid ||
        '${info['bookName'] ?? ''}'.trim().isEmpty) {
      throw const SourceException('番茄未返回对应作品详情，作品可能已下架');
    }
    final directory = await api.get(
      '/api/reader/directory/detail',
      query: {'bookId': bid},
    );
    final chapters = parseDirectory(directory);
    final seconds = int.tryParse('${info['lastPublishTime'] ?? ''}');
    return Book(
      id: bid,
      source: id,
      title: '${info['bookName']}',
      author: '${info['author'] ?? ''}',
      cover: '${info['thumbUrl'] ?? ''}',
      description: '${info['abstract'] ?? ''}',
      wordCount: Book.parseWordCount(info['wordNumber'] ?? info['word_number']),
      chapters: chapters,
      updatedAt: seconds == null || seconds <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
    );
  }

  static List<Chapter> parseDirectory(Map<String, dynamic> data) {
    final volumes = data['chapterListWithVolume'];
    if (volumes is! List) throw const SourceException('番茄目录格式已变化');
    final chapters = <Chapter>[];
    final seen = <String>{};
    for (var i = 0; i < volumes.length; i++) {
      final volume = volumes[i];
      if (volume is! List) throw const SourceException('番茄分卷格式已变化');
      for (final raw in volume) {
        if (raw is! Map) throw const SourceException('番茄章节格式已变化');
        final cid = '${raw['itemId'] ?? ''}';
        if (!_id.hasMatch(cid) || !seen.add(cid)) {
          throw const SourceException('番茄目录包含无效或重复章节');
        }
        chapters.add(
          Chapter(
            id: cid,
            title: '${raw['title'] ?? cid}',
            wordCount: Book.parseWordCount(
              raw['wordNumber'] ?? raw['word_number'],
            ),
            volume: '${raw['volume_name'] ?? '正文'}',
            vip:
                raw['isChapterLock'] == true ||
                (num.tryParse('${raw['needPay']}') ?? 0) > 0,
            url: 'https://fanqienovel.com/reader/$cid',
          ),
        );
      }
    }
    final ids = data['allItemIds'];
    if (chapters.isEmpty ||
        ids is! List ||
        ids.length != chapters.length ||
        !Iterable<int>.generate(
          ids.length,
        ).every((i) => '${ids[i]}' == chapters[i].id)) {
      throw const SourceException('番茄未返回完整章节目录');
    }
    return chapters;
  }

  @override
  Future<ChapterContent> readChapter(Book book, Chapter chapter) async {
    if (book.source != id ||
        !_id.hasMatch(book.id) ||
        !_id.hasMatch(chapter.id)) {
      throw const SourceException('番茄作品或章节 ID 无效');
    }
    final data = await api.app.chapter(book.id, chapter.id);
    final info = data['novel_data'] as Map;
    final version = '${info['version'] ?? ''}';
    if (version.isEmpty) throw const SourceException('番茄 App 未返回章节版本');
    final markup = '${data['content'] ?? ''}';
    final document = html.parse(markup);
    final expected = int.tryParse('${data['paragraphs_num']}');
    if (expected == null ||
        expected <= 0 ||
        document.querySelectorAll('p,h1,h2,img').length < expected) {
      throw const SourceException('番茄 App 未返回完整章节正文');
    }
    return parseContent(markup, itemVersion: version);
  }

  Future<ChapterContent> readPublicChapter(Book book, Chapter chapter) async {
    final response = await api.fetch(
      Uri.https('fanqienovel.com', '/reader/${chapter.id}'),
    );
    final page = utf8.decode(response.bodyBytes);
    final reader = initialState(page)['reader'];
    final data = reader is Map ? reader['chapterData'] : null;
    if (data is! Map ||
        '${data['bookId']}' != book.id ||
        '${data['itemId']}' != chapter.id) {
      throw const SourceException('番茄未返回对应章节正文');
    }
    if (data['isChapterLock'] == true ||
        (num.tryParse('${data['needPay']}') ?? 0) > 0) {
      throw const SourceException('番茄章节尚未解锁，请在官方平台确认阅读权限');
    }
    if (data['isContentIncomplete'] == true || data['isPreview'] == true) {
      throw const SourceException('番茄仅返回章节试读内容');
    }
    final raw = '${data['content'] ?? ''}';
    if (RegExp(r'[\ue000-\uf8ff]').hasMatch(raw) &&
        !page.contains('dc027189e0ba4cd')) {
      throw const SourceException('番茄正文字体已变化，请更新阅读器后重试');
    }
    return parseContent(raw);
  }

  static Map<String, dynamic> initialState(String page) {
    const prefix = 'window.__INITIAL_STATE__=';
    final start = page.indexOf(prefix);
    if (start < 0) throw const SourceException('番茄页面未返回作品数据，请完成官网验证后重试');
    final begin = start + prefix.length;
    var depth = 0, quoted = false, escaped = false;
    for (var i = begin; i < page.length; i++) {
      final c = page[i];
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          quoted = false;
        }
      } else if (c == '"') {
        quoted = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}' && --depth == 0) {
        try {
          return jsonDecode(page.substring(begin, i + 1))
              as Map<String, dynamic>;
        } catch (_) {
          break;
        }
      }
    }
    throw const SourceException('番茄页面数据格式已变化');
  }

  String _decode(String text) => text.runes.map((r) {
    if (r < 0xe000 || r > 0xf8ff) return String.fromCharCode(r);
    final value = cipher['$r'];
    if (value == null || value.isEmpty || value == '?') {
      throw const SourceException('番茄正文包含未知字体字符');
    }
    return value;
  }).join();

  ChapterContent parseContent(String raw, {String? itemVersion}) {
    // The website embeds raw JSON with unescaped quotes inside src attributes.
    // Escape only that attribute before parsing, keeping paragraph text intact.
    final markup = raw.replaceAllMapped(
      RegExp(r'''src=(["'])(\{\{image_domain\}\}\{.*?\})\1''', dotAll: true),
      (match) => 'src="${const HtmlEscape().convert(match[2]!)}"',
    );
    final document = html.parse(markup);
    final paragraphs = <Paragraph>[];
    final text = StringBuffer();
    int? remoteIndex;
    void flush() {
      final value = _decode(text.toString()).trim();
      text.clear();
      if (value.isNotEmpty) {
        paragraphs.add(
          Paragraph(value, remoteIndex: remoteIndex, remoteId: itemVersion),
        );
      }
    }

    void visit(Node node) {
      if (node is Text) {
        text.write(node.text);
        return;
      }
      if (node is! Element ||
          ['script', 'style', 'head', 'h1', 'h2'].contains(node.localName)) {
        return;
      }
      if (['p', 'div', 'br'].contains(node.localName)) flush();
      if (node.localName == 'p') {
        remoteIndex = itemVersion == null
            ? null
            : int.tryParse(node.attributes['idx'] ?? '');
        if (itemVersion != null && (remoteIndex == null || remoteIndex! < 0)) {
          throw const SourceException('番茄 App 段落编号无效');
        }
      }
      if (node.localName == 'img') {
        flush();
        var address = node.attributes['src'] ?? '';
        if (address.startsWith('{{image_domain}}')) {
          try {
            final image =
                jsonDecode(address.substring('{{image_domain}}'.length)) as Map;
            final path = '${image['web_uri'] ?? ''}';
            if (!RegExp(
              r'^novel-(?:static|pic)/[A-Za-z0-9/_-]+$',
            ).hasMatch(path)) {
              throw const FormatException();
            }
            address = 'https://p3-novel.byteimg.com/$path~tplv-noop.image';
          } catch (_) {
            throw const SourceException('番茄插图格式已变化');
          }
        }
        final uri = Uri.tryParse(
          address.startsWith('//') ? 'https:$address' : address,
        );
        if (uri == null ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const SourceException('番茄插图地址无效');
        }
        paragraphs.add(
          Paragraph(
            '',
            image: uri.replace(scheme: 'https').toString(),
            remoteIndex: remoteIndex,
            remoteId: itemVersion,
          ),
        );
        return;
      }
      for (final child in node.nodes) {
        visit(child);
      }
      if (['p', 'div'].contains(node.localName)) flush();
      if (node.localName == 'p') remoteIndex = null;
    }

    for (final node in document.nodes) {
      visit(node);
    }
    flush();
    if (paragraphs.isEmpty || !paragraphs.any((p) => p.text.isNotEmpty)) {
      throw const SourceException('番茄未返回完整正文');
    }
    return ChapterContent(paragraphs);
  }
}
