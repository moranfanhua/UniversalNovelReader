import '../../domain/models.dart';
import '../bookshelf_source.dart';
import 'ciweimao_api.dart';
import 'ciweimao_parser.dart';

mixin CiweimaoBookshelf implements BookshelfSource {
  CiweimaoApi get api;
  final _shelfPreviews = <String, Book>{};
  final _shelfIds = <String>{};
  int? _shelfGeneration;

  @override
  bool get hasSession => api.hasSession;

  void _requireAccount() {
    if (!hasSession) {
      throw const SourceException('请先在“我的 → 账号设置”登录刺猬猫');
    }
  }

  @override
  Future<List<RemoteBookshelf>> getShelves() async {
    _requireAccount();
    _shelfPreviews.clear();
    _shelfIds.clear();
    _shelfGeneration = null;
    final generation = api.sessionGeneration;
    final data = await api.request('bookshelf/get_shelf_list', {});
    final shelves = <RemoteBookshelf>[];
    final seen = <String>{};
    for (final value in CiweimaoParser.list(data['shelf_list'], '书架列表')) {
      final info = CiweimaoParser.object(value, '书架');
      final id = CiweimaoParser.numericId(info['shelf_id']);
      if (!seen.add(id) ||
          '${info['shelf_name'] ?? ''}'.trim().isEmpty ||
          info['reader_id'] != null &&
              '${info['reader_id']}' != api.credentials!.readerId) {
        throw const SourceException('刺猬猫书架编号、名称或账号不匹配');
      }
      shelves.add(RemoteBookshelf(id: id, name: '${info['shelf_name']}'));
    }
    api.checkSession(generation);
    _shelfGeneration = generation;
    _shelfIds.addAll(seen);
    return shelves;
  }

  @override
  Future<List<String>> getShelfBookIds(RemoteBookshelf shelf) async {
    _requireAccount();
    if (_shelfGeneration != api.sessionGeneration ||
        !_shelfIds.contains(shelf.id)) {
      throw const SourceException('刺猬猫账号或书架已变化，请重新读取书架');
    }
    final generation = api.sessionGeneration;
    final ids = <String>{};
    final remoteIds = <String>{};
    for (var page = 0; page < 500; page++) {
      final data = await api.request('bookshelf/get_shelf_book_list_new', {
        'shelf_id': shelf.id,
        'page': '$page',
        'count': '20',
        'order': 'zonghe',
      });
      final rows = CiweimaoParser.list(data['book_list'], '书架作品列表');
      final before = remoteIds.length;
      for (final value in rows) {
        final entry = CiweimaoParser.object(value, '书架作品');
        final info = CiweimaoParser.object(entry['book_info'], '作品详情');
        remoteIds.add(CiweimaoParser.numericId(info['book_id']));
        if ('${info['book_type'] ?? 1}' != '1') continue;
        final book = CiweimaoParser.book(info);
        ids.add(book.id);
        _shelfPreviews[book.id] = book;
      }
      api.checkSession(generation);
      if (rows.length < 20) return ids.toList();
      // Count all media when detecting progress, including shelves of comics.
      if (before == remoteIds.length) {
        throw const SourceException('刺猬猫书架分页重复，请重试');
      }
    }
    throw const SourceException('刺猬猫书架作品过多，未能完整获取');
  }

  @override
  int get shelfBookBatchSize => 4;

  @override
  Future<List<ShelfBookResult>> getShelfBooks(List<String> ids) async {
    _requireAccount();
    if (ids.length > shelfBookBatchSize) {
      throw const SourceException('刺猬猫单次获取的作品过多');
    }
    final generation = api.sessionGeneration;
    final result = await Future.wait(
      ids.map((input) async {
        try {
          final id = CiweimaoParser.numericId(input);
          final cached = _shelfGeneration == generation
              ? _shelfPreviews[id]
              : null;
          if (cached != null) return ShelfBookResult.success(input, cached);
          final data = await api.request('book/get_info_by_id', {
            'book_id': id,
            'use_daguan': '0',
          });
          api.checkSession(generation);
          final info = CiweimaoParser.object(data['book_info'], '作品详情');
          if ('${info['book_id']}' != id) {
            throw const SourceException('刺猬猫未返回对应作品详情，作品可能已下架');
          }
          return ShelfBookResult.success(input, CiweimaoParser.book(info));
        } catch (error) {
          return ShelfBookResult.failure(input, error);
        }
      }),
    );
    api.checkSession(generation);
    return result;
  }
}
