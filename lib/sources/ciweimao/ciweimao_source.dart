import 'dart:convert';

import '../../domain/models.dart';
import '../chapter_batch_source.dart';
import '../chapter_subscription_source.dart';
import '../novel_source.dart';
import '../account_source.dart';
import 'ciweimao_account.dart';
import 'ciweimao_bookshelf.dart';
import 'ciweimao_comments.dart';
import 'ciweimao_content.dart';
import 'ciweimao_crypto.dart';
import 'ciweimao_parser.dart';
import 'ciweimao_subscriptions.dart';

class CiweimaoSource extends CiweimaoComments
    with CiweimaoBookshelf, CiweimaoSubscriptions, CiweimaoAccount
    implements
        SearchableNovelSource,
        ChapterBatchSource,
        BookUpdateSource,
        AccountSource {
  CiweimaoSource(super.api);
  @override
  String get id => 'ciweimao';
  @override
  String get name => '刺猬猫阅读';
  static String bookId(String input) => CiweimaoParser.bookId(input);
  static bool acceptsLink(String input) {
    if (RegExp(r'^\d+$').hasMatch(input.trim())) return false;
    try {
      bookId(input);
      return true;
    } on SourceException {
      return false;
    }
  }

  @override
  Future<List<Book>> search(String keyword, {int page = 0}) async {
    if (keyword.trim().isEmpty) return [];
    if (page < 0) throw const SourceException('搜索页码无效');
    final data = await api.request(
      'bookcity/get_search_book_list_by_bookname',
      {'key': keyword.trim(), 'page': '$page', 'count': '20', 'mode': '0'},
    );
    final books = <String, Book>{};
    for (final raw in CiweimaoParser.list(data['book_list'], '搜索结果')) {
      final info = CiweimaoParser.object(raw, '搜索作品');
      if ('${info['book_type'] ?? 1}' != '1') continue;
      final book = CiweimaoParser.book(info);
      books.putIfAbsent(book.id, () => book);
    }
    return books.values.toList();
  }

  @override
  Future<Book> getBookUpdate(String input) async {
    final bid = bookId(input);
    final details = await api.requestPublic('book/get_info_by_id', {
      'book_id': bid,
      'use_daguan': '0',
    });
    final info = CiweimaoParser.object(details['book_info'], '作品详情');
    if ('${info['book_id']}' != bid) {
      throw const SourceException('刺猬猫未返回对应作品详情，作品可能已下架');
    }
    return CiweimaoParser.book(info);
  }

  @override
  Future<Book> getBook(String input) async {
    final preview = await getBookUpdate(input);
    final directory = await api.requestPublic(
      'chapter/get_updated_chapter_by_division_new',
      {'book_id': preview.id, 'division_id': '0'},
    );
    return preview.withChapters(CiweimaoParser.directory(directory));
  }

  void _validate(Book book, List<Chapter> chapters) {
    if (book.source != id ||
        chapters.map((c) => c.id).toSet().length != chapters.length ||
        chapters.any((c) => !book.chapters.any((entry) => entry.id == c.id))) {
      throw const SourceException('刺猬猫作品与章节不匹配');
    }
    CiweimaoParser.numericId(book.id);
    for (final c in chapters) {
      CiweimaoParser.numericId(c.id);
    }
  }

  Future<Set<String>> _permitted(Book book, List<Chapter> chapters) async {
    final vipIds = book.chapters.where((c) => c.vip).map((c) => c.id).toSet();
    final free = chapters
        .where((c) => !vipIds.contains(c.id))
        .map((c) => c.id)
        .toSet();
    if (free.length == chapters.length) return free;
    if (!api.hasSession) return free;
    final data = await api.request('chapter/get_chapter_permission_list', {
      'book_id': book.id,
    });
    final owned = <String>{};
    for (final entry in CiweimaoParser.list(
      data['chapter_permission_list'],
      '章节权限',
    )) {
      final info = CiweimaoParser.object(entry, '章节权限');
      final cid = CiweimaoParser.numericId(info['chapter_id']);
      if (!owned.add(cid)) throw const SourceException('刺猬猫返回了重复的章节权限');
      if ('${info['auth_access']}' == '1') free.add(cid);
    }
    return free;
  }

  SourceException _noAccess() => SubscriptionRequiredException(
    api.hasSession
        ? '此章节暂无阅读权限，可订阅后续章节或在刺猬猫官方 App 确认可读状态'
        : '请先在“我的 → 账号设置”登录刺猬猫，仅可读取已有权限章节',
  );

  @override
  Future<ChapterContent> readChapter(Book book, Chapter chapter) async {
    _validate(book, [chapter]);
    await api.ensureSession();
    final generation = api.sessionGeneration;
    final permitted = await _permitted(book, [chapter]);
    api.checkSession(generation);
    if (!permitted.contains(chapter.id)) throw _noAccess();
    final data = await api.request('chapter/get_chapter_cmd', {
      'chapter_id': chapter.id,
    });
    final command = _command(data);
    final payload = await api.request('chapter/get_cpt_ifm', {
      'chapter_id': chapter.id,
      'chapter_command': command,
    });
    final info = CiweimaoParser.object(payload['chapter_info'], '章节正文');
    if ('${info['chapter_id']}' != chapter.id ||
        '${info['book_id']}' != book.id) {
      throw const SourceException('刺猬猫返回的正文与作品、章节不匹配');
    }
    if ('${info['auth_access']}' != '1') throw _noAccess();
    final text = info['txt_content'];
    if (text is! String || text.isEmpty) {
      throw const SourceException('刺猬猫未返回完整正文，请重试');
    }
    final String body;
    if ('${info['use_cdn'] ?? 0}' == '1') {
      body = await CiweimaoContent.fetch(api, text);
    } else if ('${info['use_cdn'] ?? 0}' == '0') {
      body = CiweimaoCrypto.decrypt(text, seed: command);
    } else {
      throw const SourceException('刺猬猫正文传输格式已变化');
    }
    api.checkSession(generation);
    return _content(body, info);
  }

  static String _command(Map<String, dynamic> data) {
    final command = data['command'];
    if (command is! String || command.isEmpty) {
      throw const SourceException('刺猬猫未返回章节阅读参数');
    }
    return command;
  }

  static ChapterContent _content(String text, Map<String, dynamic> info) {
    final rawHost = info['cdn_path'];
    final host = rawHost is String && CiweimaoContent.validCdnHost(rawHost)
        ? rawHost
        : null;
    final oldHosts = info['need_replace_cdn_path'];
    return CiweimaoParser.content(
      text,
      authorSay: '${info['author_say'] ?? ''}',
      cdnHost: host,
      oldHosts: oldHosts is List
          ? oldHosts.whereType<String>().toList()
          : const [],
    );
  }

  // BuyDownThread sends ten IDs per command and uses at most ten workers.
  @override
  int get chapterBatchSize => 10;
  @override
  int get chapterBatchConcurrency => 10;

  @override
  Future<List<ChapterBatchResult>> readChapterBatch(
    Book book,
    List<Chapter> chapters,
  ) async {
    _validate(book, chapters);
    if (chapters.length > chapterBatchSize) {
      throw const SourceException('刺猬猫单批下载章节过多');
    }
    if (chapters.isEmpty) return [];
    await api.ensureSession();
    final generation = api.sessionGeneration;
    final permitted = await _permitted(book, chapters);
    api.checkSession(generation);
    final allowed = chapters.where((c) => permitted.contains(c.id)).toList();
    final results = <String, ChapterBatchResult>{
      for (final c in chapters.where((c) => !permitted.contains(c.id)))
        c.id: ChapterBatchResult.failure(c.id, _noAccess()),
    };
    if (allowed.isNotEmpty) {
      final ids = allowed.map((c) => c.id).join(',');
      final command = _command(
        await api.request('chapter/get_chapter_download_cmd', {
          'chapter_id': ids,
        }),
      );
      final data = await api.request('chapter/download_cpt', {
        'chapter_id': ids,
        'chapter_command': command,
      });
      final encrypted = data['chapter_infos'];
      if (encrypted is! String) throw const SourceException('刺猬猫批量正文格式已变化');
      final raw = jsonDecode(CiweimaoCrypto.decrypt(encrypted, seed: command));
      final entries = <String, Map<String, dynamic>>{};
      for (final value in CiweimaoParser.list(raw, '批量正文')) {
        final info = CiweimaoParser.object(value, '批量章节');
        final cid = CiweimaoParser.numericId(info['chapter_id']);
        if (!allowed.any((c) => c.id == cid) ||
            entries.containsKey(cid) ||
            info['book_id'] != null && '${info['book_id']}' != book.id) {
          throw const SourceException('刺猬猫批量正文包含不匹配或重复章节');
        }
        entries[cid] = info;
      }
      api.checkSession(generation);
      for (final chapter in allowed) {
        try {
          final info = entries[chapter.id];
          if (info == null) throw const SourceException('刺猬猫未返回此章节，请重试');
          if ('${info['auth_access']}' != '1') throw _noAccess();
          if (info['txt_content'] is! String) {
            throw const SourceException('刺猬猫未返回完整正文');
          }
          results[chapter.id] = ChapterBatchResult.success(
            chapter.id,
            _content(info['txt_content'] as String, info),
          );
        } catch (error) {
          results[chapter.id] = ChapterBatchResult.failure(chapter.id, error);
        }
      }
    }
    return [for (final c in chapters) results[c.id]!];
  }
}
