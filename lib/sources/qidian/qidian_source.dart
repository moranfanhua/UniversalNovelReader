import 'dart:convert';

import '../../domain/models.dart';
import '../novel_source.dart';
import 'qidian_api.dart';
import 'qidian_crypto.dart';
import 'qidian_fock.dart';

class QidianSource implements SearchableNovelSource {
  QidianSource(this.api);
  final QidianApi api;
  @override
  String get id => 'qidian';
  @override
  String get name => '起点读书';

  static String bookId(String input) {
    final value = input.trim();
    if (RegExp(r'^[1-9]\d{0,11}$').hasMatch(value)) return value;
    final match = RegExp(r'https?://[^\s<>「」“”]+').firstMatch(value);
    final uri = match == null ? null : Uri.tryParse(match[0]!);
    if (uri != null &&
        {
          'qidian.com',
          'www.qidian.com',
          'book.qidian.com',
          'm.qidian.com',
        }.contains(uri.host.toLowerCase()) &&
        uri.userInfo.isEmpty &&
        (!uri.hasPort || uri.port == 443 || uri.port == 80)) {
      final path = RegExp(r'^/(?:book|info)/(\d+)/?$').firstMatch(uri.path);
      final bid = path?[1] ?? uri.queryParameters['bookId'];
      if (bid != null && RegExp(r'^[1-9]\d{0,11}$').hasMatch(bid)) return bid;
    }
    throw const SourceException('请输入起点作品 ID 或作品链接');
  }

  static String _cover(String bid) =>
      'https://bookcover.yuewen.com/qdbimg/349573/$bid/180';

  @override
  Future<List<Book>> search(String keyword, {int page = 0}) async {
    if (keyword.trim().isEmpty) return [];
    if (page < 0) throw const SourceException('搜索页码无效');
    final data = await api.request('/argus/api/v2/booksearch/searchbooks', {
      'keyword': keyword.trim(),
      'keywordType': '-1',
      'siteId': '1',
      'pageSize': '20',
      'pageIndex': '${page + 1}',
    }, post: true);
    final cards = data['CardList'];
    if (cards == null && '${data['TotalCount']}' == '0') return [];
    if (cards is! List) throw const SourceException('起点搜索结果格式已变化');
    final books = <String, Book>{};
    for (final card in cards.whereType<Map>()) {
      final body = card['Body'];
      if (body is! List) continue;
      for (final row in body.whereType<Map>()) {
        final item = row['ItemData'];
        if (item is! Map || '${item['BookType']}' != '1') continue;
        final bid = bookId('${item['BookId']}');
        final title = '${item['BookName'] ?? ''}'.trim();
        if (title.isEmpty) continue;
        books[bid] = Book(
          id: bid,
          source: id,
          title: title,
          author: '${item['AuthorName'] ?? ''}',
          cover: _cover(bid),
          description: '${item['Description'] ?? ''}',
          wordCount: Book.parseWordCount(item['WordsCount']),
          chapters: [],
        );
      }
    }
    return books.values.toList();
  }

  @override
  Future<Book> getBook(String input) async {
    final bid = bookId(input);
    final data = await api.request('/argus/api/v3/bookdetail/get', {
      'bookId': bid,
      'isOutBook': '0',
    });
    final info = data['BaseBookInfo'];
    if (info is! Map ||
        '${info['BookId']}' != bid ||
        '${info['BookName'] ?? ''}'.trim().isEmpty) {
      throw const SourceException('起点未返回对应作品详情，作品可能已下架');
    }
    final directory = await api
        .request('/argus/api/v3/chapterlist/chapterlist', {
          'bookId': bid,
          'timeStamp': '0',
          'requestSource': '0',
          'md5Signature': '',
          'extendchapterIds': '',
        });
    if ('${directory['BookId']}' != bid) {
      throw const SourceException('起点目录作品编号不匹配');
    }
    final author = data['AuthorInfo'];
    final chapterInfo = info['ChapterInfo'];
    final updated = chapterInfo is Map
        ? int.tryParse('${chapterInfo['LastChapterUpdateTime']}')
        : null;
    return Book(
      id: bid,
      source: id,
      title: '${info['BookName']}',
      author: author is Map
          ? '${author['Author'] ?? directory['Author'] ?? ''}'
          : '${directory['Author'] ?? ''}',
      cover: _cover(bid),
      description: '${info['Description'] ?? ''}',
      wordCount: Book.parseWordCount(info['WordsCnt']),
      updatedAt: updated == null || updated <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(updated, isUtc: true),
      chapters: parseDirectory(directory),
    );
  }

  static List<Chapter> parseDirectory(Map<String, dynamic> data) {
    final raw = data['Chapters'], volumes = data['Volumes'];
    if (raw is! List || volumes is! List) {
      throw const SourceException('起点目录格式已变化');
    }
    final names = {
      for (final v in volumes.whereType<Map>())
        '${v['VolumeCode']}': '${v['VolumeName'] ?? ''}',
    };
    final items = <Map>[];
    final seen = <String>{};
    for (final entry in raw) {
      if (entry is! Map) throw const SourceException('起点章节格式已变化');
      // The App inserts a copyright pseudo-chapter with C=-10000.
      if ('${entry['C']}' == '-10000') continue;
      final cid = bookId('${entry['C']}');
      if (!seen.add(cid) ||
          '${entry['N'] ?? ''}'.trim().isEmpty ||
          int.tryParse('${entry['O']}') == null) {
        throw const SourceException('起点章节编号、名称或顺序无效');
      }
      items.add(entry);
    }
    final volumeOrder = names.keys.toList();
    if (items.any((c) => !names.containsKey('${c['Vc']}'))) {
      throw const SourceException('起点目录缺少分卷信息');
    }
    items.sort((a, b) {
      final volume = volumeOrder
          .indexOf('${a['Vc']}')
          .compareTo(volumeOrder.indexOf('${b['Vc']}'));
      return volume != 0
          ? volume
          : int.parse('${a['O']}').compareTo(int.parse('${b['O']}'));
    });
    if (items.isEmpty) throw const SourceException('起点作品尚无可读章节');
    return [
      for (final c in items)
        Chapter(
          id: '${c['C']}',
          title: '${c['N']}',
          volume: names['${c['Vc']}'] ?? '',
          vip: '${c['V']}' == '1',
          wordCount: Book.parseWordCount(c['W']),
        ),
    ];
  }

  @override
  Future<ChapterContent> readChapter(Book book, Chapter chapter) async {
    if (book.source != id || !book.chapters.any((c) => c.id == chapter.id)) {
      throw const SourceException('起点作品与章节不匹配');
    }
    final bid = bookId(book.id), cid = bookId(chapter.id);
    final vip = book.chapters.firstWhere((c) => c.id == cid).vip;
    final session = api.credentials;
    if (vip && session == null) {
      throw const SourceException('请先在“我的 → 账号设置”登录起点读书，仅可读取已有权限章节');
    }
    void checkSession() {
      if (!identical(session, api.credentials)) {
        throw const SourceException('起点账号已切换，请重新打开章节');
      }
    }

    if (vip) {
      // The download endpoint must never be used to trigger auto-subscription.
      // Confirm ownership first, even when the official App enables auto-buy.
      final owned = api.responsePayload(
        await api.send('/argus/api/v2/subscription/getboughtchapterlist', {
          'bookId': bid,
        }, post: true),
      );
      checkSession();
      if (owned is! List) throw const SourceException('起点已购章节列表格式已变化');
      if (!owned.any((id) => '$id' == cid)) {
        throw const SourceException('此章节尚未购买，请先在起点官方 App 购买后重试');
      }
    }
    final response = await api.send(
      vip
          ? '/argus/api/v4/bookcontent/getvipcontent'
          : '/argus/api/v2/bookcontent/safegetcontent',
      vip
          ? {'b': bid, 'c': cid, 'ui': '0', 'b-string': ''}
          : {'bookId': bid, 'chapterId': cid},
      post: vip,
    );
    checkSession();
    if (response.statusCode != 200 ||
        response.bodyBytes.isEmpty ||
        response.bodyBytes.first == 0x7b) {
      api.responseData(response);
      throw const SourceException('起点未返回章节正文');
    }
    final data = QidianCrypto.decodeChapter(
      response.bodyBytes,
      chapterId: cid,
      device: api.device,
      userId: session?.userId ?? '0',
    );
    final code = int.tryParse('${data['code'] ?? 0}');
    if (code != 0) {
      throw SourceException('该起点章节暂无阅读权限，请在官方 App 确认可读状态', code: code ?? -1);
    }
    var content = data['Content'] ?? data['content'];
    if (content is! String || content.trim().isEmpty) {
      throw const SourceException('起点未返回完整正文，请重试');
    }
    final type = '${data['type'] ?? 0}';
    if (type == '1') {
      if (!vip) throw const SourceException('起点免费章节加密格式已变化');
      final keyData = await api.request('/argus/api/v4/bookcontent/getkey', {
        'bookId': bid,
        'ui': '0',
      });
      checkSession();
      content = QidianFock.decode(
        content,
        chapterId: cid,
        device: api.device,
        readingKey: QidianReadingKey.fromJson(keyData),
      );
    } else if (type != '0') {
      throw const SourceException('起点正文加密格式暂不支持');
    }
    return parseContent(content, data['Blocks']);
  }

  static ChapterContent parseContent(String content, Object? rawBlocks) {
    if (rawBlocks != null && rawBlocks is! List) {
      throw const SourceException('起点章节插图格式已变化');
    }
    // Official ChapterProvider attaches blocks after the numbered paragraph;
    // Attach=0 appears before the first body paragraph, ordered by Sort.
    final lines = const LineSplitter().convert(
      content.replaceAll(RegExp(r'\r+\n'), '\n').replaceAll('\r', '\n'),
    );
    final attachments = <int, List<Map>>{};
    for (final block in (rawBlocks as List? ?? [])) {
      if (block is! Map || !{'image', '1', '4'}.contains('${block['Type']}')) {
        throw const SourceException('本章含暂不支持的图文或音视频格式，请在起点官方 App 阅读');
      }
      final position = int.tryParse('${block['Attach']}');
      final url = Uri.tryParse('${block['Url'] ?? ''}');
      if (position == null ||
          position < 0 ||
          position > lines.length ||
          url == null ||
          !{'https', 'http'}.contains(url.scheme) ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty) {
        throw const SourceException('起点章节插图位置或地址无效，请重试');
      }
      (attachments[position] ??= []).add(block);
    }
    final paragraphs = <Paragraph>[];
    for (var i = 0; i <= lines.length; i++) {
      if (i > 0 && lines[i - 1].trim().isNotEmpty) {
        paragraphs.add(Paragraph(lines[i - 1].trim()));
      }
      final images = attachments[i] ?? [];
      images.sort(
        (a, b) => (int.tryParse('${a['Sort']}') ?? 0).compareTo(
          int.tryParse('${b['Sort']}') ?? 0,
        ),
      );
      for (final image in images) {
        paragraphs.add(Paragraph('', image: '${image['Url']}'));
      }
    }
    if (paragraphs.isEmpty) throw const SourceException('起点未返回完整正文，请重试');
    return ChapterContent(paragraphs);
  }
}
