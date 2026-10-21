import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../domain/models.dart';
import '../novel_source.dart';
import '../account_source.dart';
import '../chapter_batch_source.dart';
import '../chapter_subscription_source.dart';
import 'qidian_api.dart';
import 'qidian_account.dart';
import 'qidian_comments.dart';
import 'qidian_crypto.dart';
import 'qidian_fock.dart';
import 'qidian_subscriptions.dart';

class QidianSource extends QidianComments
    with QidianSubscriptions, QidianAccount
    implements
        SearchableNovelSource,
        ChapterBatchSource,
        BookUpdateSource,
        AccountSource {
  QidianSource(super.api);
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
    final items = <String, Map>{};
    for (final card in cards.whereType<Map>()) {
      final body = card['Body'];
      if (body is! List) continue;
      for (final row in body.whereType<Map>()) {
        final item = row['ItemData'];
        if (item is! Map || '${item['BookType']}' != '1') continue;
        final bid = bookId('${item['BookId']}');
        final title = '${item['BookName'] ?? ''}'.trim();
        if (title.isEmpty) continue;
        items[bid] = item;
      }
    }
    // UNR uses BssRecomTotal as the Qidian favorite/sort count.
    final favorites = {
      for (final entry in items.entries)
        entry.key: Book.parseFavoriteCount(entry.value['BssRecomTotal']),
    };
    final missing = items.keys.where((bid) => favorites[bid] == null).toList();
    // Search currently omits the counter. Fetch details without chapter lists,
    // limiting concurrency and keeping successful search hits on lookup failure.
    for (var offset = 0; offset < missing.length; offset += 4) {
      await Future.wait(
        missing.skip(offset).take(4).map((bid) async {
          try {
            final data = await _details(bid);
            favorites[bid] = Book.parseFavoriteCount(
              (data['BaseBookInfo'] as Map)['BssRecomTotal'],
            );
          } on Exception {
            // Unknown popularity must not discard a successful search result.
          }
        }),
      );
    }
    return [
      for (final entry in items.entries)
        Book(
          id: entry.key,
          source: id,
          title: '${entry.value['BookName']}'.trim(),
          author: '${entry.value['AuthorName'] ?? ''}',
          cover: _cover(entry.key),
          description: '${entry.value['Description'] ?? ''}',
          favoriteCount: favorites[entry.key],
          wordCount: Book.parseWordCount(entry.value['WordsCount']),
          chapters: [],
        ),
    ];
  }

  @override
  Future<Book> getBookUpdate(String input) async {
    final bid = bookId(input);
    final data = await _details(bid);
    return _bookPreview(bid, data);
  }

  Future<Map<String, dynamic>> _details(String bid) async {
    final data = await api.request('/argus/api/v3/bookdetail/get', {
      'bookId': bid,
      'isOutBook': '0',
    }, useSession: false);
    final info = data['BaseBookInfo'];
    if (info is! Map ||
        '${info['BookId']}' != bid ||
        '${info['BookName'] ?? ''}'.trim().isEmpty) {
      throw const SourceException('起点未返回对应作品详情，作品可能已下架');
    }
    return data;
  }

  @override
  Future<Book> getBook(String input) async {
    final bid = bookId(input);
    final data = await _details(bid);
    final directory = await api
        .request('/argus/api/v3/chapterlist/chapterlist', {
          'bookId': bid,
          'timeStamp': '0',
          'requestSource': '0',
          'md5Signature': '',
          'extendchapterIds': '',
        }, useSession: false);
    if ('${directory['BookId']}' != bid) {
      throw const SourceException('起点目录作品编号不匹配');
    }
    return _bookPreview(
      bid,
      data,
      fallbackAuthor: '${directory['Author'] ?? ''}',
    ).withChapters(parseDirectory(directory));
  }

  Book _bookPreview(
    String bid,
    Map<String, dynamic> data, {
    String fallbackAuthor = '',
  }) {
    final info = data['BaseBookInfo'] as Map;
    final author = data['AuthorInfo'];
    final chapterInfo = info['ChapterInfo'];
    final updated = chapterInfo is Map
        ? math.max(
            int.tryParse('${chapterInfo['LastChapterUpdateTime']}') ?? 0,
            int.tryParse('${chapterInfo['LastVipChapterUpdateTime']}') ?? 0,
          )
        : 0;
    return Book(
      id: bid,
      source: id,
      title: '${info['BookName']}',
      author: author is Map
          ? '${author['Author'] ?? fallbackAuthor}'
          : fallbackAuthor,
      cover: _cover(bid),
      description: '${info['Description'] ?? ''}',
      favoriteCount: Book.parseFavoriteCount(info['BssRecomTotal']),
      wordCount: Book.parseWordCount(info['WordsCnt']),
      updatedAt: updated <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(updated, isUtc: true),
      chapters: const [],
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
        throw const SubscriptionRequiredException('此章节尚未购买，可订阅后续章节');
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
    return _decodeContent(bid, cid, vip, response.bodyBytes, session);
  }

  void _checkSession(QidianCredentials? session) {
    if (!identical(session, api.credentials)) {
      throw const SourceException('起点账号已切换，请重新下载章节');
    }
  }

  Future<QidianReadingKey> _readingKey(
    String bid,
    QidianCredentials? session,
  ) async {
    final data = await api.request('/argus/api/v4/bookcontent/getkey', {
      'bookId': bid,
      'ui': '0',
    });
    _checkSession(session);
    return QidianReadingKey.fromJson(data);
  }

  Future<ChapterContent> _decodeContent(
    String bid,
    String cid,
    bool vip,
    Uint8List bytes,
    QidianCredentials? session, {
    Future<QidianReadingKey> Function()? getKey,
  }) async {
    _checkSession(session);
    final data = QidianCrypto.decodeChapter(
      bytes,
      chapterId: cid,
      device: api.device,
      userId: session?.userId ?? '0',
    );
    final code = int.tryParse('${data['code'] ?? 0}');
    if (code != 0) {
      throw SourceException('该起点章节暂无阅读权限，请在官方 App 确认可读状态', code: code ?? -1);
    }
    var content = data['Content'] ?? data['content'] ?? '';
    if (content is! String) {
      throw const SourceException('起点未返回完整正文，请重试');
    }
    final type = '${data['type'] ?? 0}';
    if (type == '1') {
      if (!vip) throw const SourceException('起点免费章节加密格式已变化');
      // Image-only chapters have no FOCK text payload. The block parser below
      // still requires valid content before the chapter can enter the cache.
      if (content.trim().isNotEmpty) {
        final key = await (getKey?.call() ?? _readingKey(bid, session));
        _checkSession(session);
        content = QidianFock.decode(
          content,
          chapterId: cid,
          device: api.device,
          readingKey: key,
        );
      }
    } else if (type != '0') {
      throw const SourceException('起点正文加密格式暂不支持');
    }
    return parseContent(content, data['Blocks']);
  }

  @override
  int get chapterBatchSize => 100;
  @override
  int get chapterBatchConcurrency => 1;

  @override
  Future<List<ChapterBatchResult>> readChapterBatch(
    Book book,
    List<Chapter> chapters,
  ) async {
    if (chapters.isEmpty) return [];
    if (book.source != id ||
        chapters.length > chapterBatchSize ||
        chapters.map((c) => c.id).toSet().length != chapters.length) {
      throw const SourceException('起点批量下载作品或章节数量无效');
    }
    final bid = bookId(book.id);
    final directory = {
      for (final chapter in book.chapters) chapter.id: chapter,
    };
    final session = api.credentials;
    final results = <String, ChapterBatchResult>{};
    Set<String> owned = {};
    Object? ownershipError;
    if (chapters.any((c) => directory[c.id]?.vip == true)) {
      try {
        if (session == null) throw const SourceException('请先登录起点读书，仅可下载已有权限章节');
        final payload = api.responsePayload(
          await api.send('/argus/api/v2/subscription/getboughtchapterlist', {
            'bookId': bid,
          }, post: true),
        );
        _checkSession(session);
        if (payload is! List) throw const SourceException('起点已购章节列表格式已变化');
        owned = payload.map((value) => '$value').toSet();
      } catch (error) {
        ownershipError = error;
      }
    }
    _checkSession(session);
    final eligible = <Chapter>[];
    for (final chapter in chapters) {
      final selected = directory[chapter.id];
      if (selected == null) {
        results[chapter.id] = ChapterBatchResult.failure(
          chapter.id,
          const SourceException('起点作品与章节不匹配'),
        );
      } else if (selected.vip && !owned.contains(selected.id)) {
        results[selected.id] = ChapterBatchResult.failure(
          selected.id,
          ownershipError ??
              const SubscriptionRequiredException('此章节尚未购买，可订阅后续章节'),
        );
      } else {
        bookId(selected.id);
        eligible.add(selected);
      }
    }
    if (eligible.isNotEmpty) {
      try {
        // Official QDChapterBatchDownloadLoader, default 100 chapters per task.
        final data = await api.request(
          '/argus/newapi/v1/bookcontent/getcontentbatch',
          {'b': bid, 'c': eligible.map((c) => c.id).join(','), 'useImei': '0'},
          post: true,
        );
        _checkSession(session);
        final key = await _readingKey(bid, session);
        // FockUtil.unlock(DownloadUrl, bookId, "BatchChapterCos_...") uses the
        // book ID for key derivation; the third argument is its cache label.
        final address = QidianFock.decode(
          '${data['DownloadUrl'] ?? ''}',
          chapterId: bid,
          device: api.device,
          readingKey: key,
        );
        final bytes = await api.downloadArchive(
          address,
          '${data['Md5'] ?? ''}',
        );
        _checkSession(session);
        final decoder = ZipDecoder();
        final archive = decoder.decodeBytes(bytes);
        if (decoder.directory.fileHeaders.length != archive.files.length) {
          throw const SourceException('起点批量文件包含重复章节');
        }
        final entries = <String, ArchiveFile>{};
        final requested = eligible.map((c) => c.id).toSet();
        var totalBytes = 0;
        for (final file in archive.files) {
          if (!file.isFile) continue;
          final match = RegExp(
            '^${bid}_([1-9]\\d{0,11})_\\d{1,20}\\.qd\$',
          ).firstMatch(file.name);
          final cid = match?[1];
          totalBytes += file.size;
          if (cid == null ||
              !requested.contains(cid) ||
              entries.containsKey(cid) ||
              file.size > 2 * 1024 * 1024 ||
              totalBytes > 32 * 1024 * 1024) {
            throw const SourceException('起点批量文件包含不匹配、重复或过大的章节');
          }
          entries[cid] = file;
        }
        for (final chapter in eligible) {
          try {
            final file = entries[chapter.id];
            if (file == null) throw const SourceException('起点未返回该章节正文，请重试');
            final contentBytes = file.content;
            if (contentBytes.length != file.size ||
                getCrc32(contentBytes) != file.crc32) {
              throw const SourceException('起点章节文件校验失败，请重试');
            }
            final content = await _decodeContent(
              bid,
              chapter.id,
              chapter.vip,
              contentBytes,
              session,
              getKey: () async => key,
            );
            results[chapter.id] = ChapterBatchResult.success(
              chapter.id,
              content,
            );
          } catch (error) {
            results[chapter.id] = ChapterBatchResult.failure(chapter.id, error);
          }
        }
      } catch (error) {
        for (final chapter in eligible) {
          results[chapter.id] = ChapterBatchResult.failure(chapter.id, error);
        }
      }
    }
    _checkSession(session);
    return chapters.map((c) => results[c.id]!).toList();
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
        paragraphs.add(Paragraph(lines[i - 1].trim(), remoteIndex: i));
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
