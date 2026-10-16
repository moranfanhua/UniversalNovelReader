import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:pinyin/pinyin.dart';
import '../domain/models.dart';
import '../domain/reading_preferences.dart';
import '../domain/bookshelf.dart';
import '../sources/bookshelf_source.dart';
import '../sources/sfacg/sfacg_source.dart';
import '../sources/comment_source.dart';
import '../sources/novel_source.dart';
import 'reader_fonts.dart';
import 'app_log.dart';

enum ReadingMode { scroll, paged }

enum AppThemeMode { system, light, dark }

enum ShelfSort { updated, name, lastActive }

enum ShelfLayout { grid, list }

extension ShelfSortLabel on ShelfSort {
  String get label => switch (this) {
    ShelfSort.updated => '按更新时间',
    ShelfSort.name => '按名称',
    ShelfSort.lastActive => '按上次活跃时间',
  };
}

class Library extends ChangeNotifier {
  Library(
    this.root,
    this.source, {
    ReaderFonts? fonts,
    DateTime Function()? clock,
    Iterable<CommentSource> commentSources = const [],
    Iterable<NovelSource> novelSources = const [],
  }) : fonts = fonts ?? ReaderFonts(Directory('${root.path}/fonts')),
       clock = clock ?? DateTime.now,
       _novelSources = {
         source.id: source,
         for (final service in novelSources) service.id: service,
       },
       _commentSources = {
         source.id: source,
         for (final service in novelSources.whereType<CommentSource>())
           service.id: service,
         for (final service in commentSources) service.id: service,
       };
  final Map<String, NovelSource> _novelSources;
  NovelSource? sourceFor(Book book) => _novelSources[book.source];
  List<SearchableNovelSource> get searchSources =>
      _novelSources.values.whereType<SearchableNovelSource>().toList();
  final Set<String> _disabledSearchSources = {};
  bool isSearchSourceEnabled(String id) => !_disabledSearchSources.contains(id);
  List<SearchableNovelSource> get enabledSearchSources => searchSources
      .where((source) => isSearchSourceEnabled(source.id))
      .toList();
  List<BookshelfSource> get bookshelfSources =>
      _novelSources.values.whereType<BookshelfSource>().toList();
  String sourceName(Book book) =>
      sourceFor(book)?.name ?? (book.source == 'local' ? '本地小说' : '未知书源');
  final Map<String, CommentSource> _commentSources;
  CommentSource? commentsFor(Book book) => _commentSources[book.source];
  final DateTime Function() clock;
  final ReaderFonts fonts;
  final Directory root;
  final SfacgSource source;
  final List<Book> books = [];
  static const recentShelfId = '__recent__';
  static const recentBookLimit = 50;
  final List<Book> recentBooks = [];
  bool isOnShelf(Book book) => books.any((item) => item.key == book.key);
  final Set<String> _pinnedBookKeys = {};
  bool isBookPinned(Book book) => _pinnedBookKeys.contains(book.key);
  List<Book> _pinnedFirst(List<Book> items) => [
    ...items.where(isBookPinned),
    ...items.where((book) => !isBookPinned(book)),
  ];
  List<Book> get sortedRecentBooks => _pinnedFirst(recentBooks);
  final List<Bookshelf> shelves = [];
  ShelfSort shelfSort = ShelfSort.lastActive;
  ShelfLayout shelfLayout = ShelfLayout.grid;
  final Map<String, int> updatedTimes = {}, lastActiveTimes = {};
  final Map<String, String> _nameSortKeys = {};
  static String _nameSortKey(String title) {
    final text = title.trim().toLowerCase();
    try {
      return PinyinHelper.getPinyin(
        text,
        separator: '',
        format: PinyinFormat.WITHOUT_TONE,
      ).toLowerCase();
    } on PinyinException {
      // An unsupported character must not prevent the shelf from opening.
      return text.runes.map((rune) {
        final character = String.fromCharCode(rune);
        try {
          return PinyinHelper.getPinyin(
            character,
            separator: '',
            format: PinyinFormat.WITHOUT_TONE,
          ).toLowerCase();
        } on PinyinException {
          return character;
        }
      }).join();
    }
  }

  int _updatedTime(Book book) => book.source == 'local'
      ? updatedTimes[book.key] ?? 0
      : book.updatedAt?.millisecondsSinceEpoch ?? updatedTimes[book.key] ?? 0;
  List<Book> get sortedBooks {
    final result = books.toList();
    final position = {for (var i = 0; i < books.length; i++) books[i].key: i};
    final names = <String, String>{};
    if (shelfSort == ShelfSort.name) {
      final titles = books.map((book) => book.title).toSet();
      _nameSortKeys.removeWhere((title, _) => !titles.contains(title));
      for (final book in books) {
        names[book.key] = _nameSortKeys.putIfAbsent(
          book.title,
          () => _nameSortKey(book.title),
        );
      }
    }
    result.sort((a, b) {
      final comparison = switch (shelfSort) {
        ShelfSort.name => names[a.key]!.compareTo(names[b.key]!),
        ShelfSort.updated => _updatedTime(b).compareTo(_updatedTime(a)),
        ShelfSort.lastActive => (lastActiveTimes[b.key] ?? 0).compareTo(
          lastActiveTimes[a.key] ?? 0,
        ),
      };
      return comparison == 0
          ? position[a.key]!.compareTo(position[b.key]!)
          : comparison;
    });
    return _pinnedFirst(result);
  }

  final Map<String, List<int>> progress = {};
  double fontSize = 20;
  AppThemeMode themeMode = AppThemeMode.system;
  ReadingMode readingMode = ReadingMode.scroll;
  bool volumeKeyPaging = true;
  bool showParagraphComments = true;
  ParagraphCommentPlacement paragraphCommentPlacement =
      ParagraphCommentPlacement.right;
  final Map<String, int> pageOffsets = {};
  // Entry alignment and preceding spread origin, indexed by book and chapter.
  final Map<String, List<int>> pagedChapterEntries = {};
  String readingFontId = '';
  String? readingFontFamily, fontNotice;
  final downloadedFonts = <String>{};
  double horizontalMargin = 22, verticalMargin = 24, lineHeight = 1.9;
  Future<void> _writes = Future.value();
  final Map<String, Future<ChapterContent>> _reads = {};
  final Map<String, Future<Uint8List>> _imageReads = {};
  final Map<String, Future<void>> _fileWrites = {};
  static String safeKey(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static Future<Library> open(
    SfacgSource source, {
    Directory? directory,
    ReaderFonts? fonts,
    DateTime Function()? clock,
    Iterable<CommentSource> commentSources = const [],
    Iterable<NovelSource> novelSources = const [],
  }) async {
    final dir =
        directory ??
        Directory('${(await getApplicationSupportDirectory()).path}/library');
    await dir.create(recursive: true);
    final library = Library(
      dir,
      source,
      fonts: fonts,
      clock: clock,
      commentSources: commentSources,
      novelSources: novelSources,
    );
    final file = File('${dir.path}/index.json');
    if (await file.exists()) {
      final data = jsonDecode(await file.readAsString()) as Map;
      library.books.addAll(
        (data['books'] as List).map(
          (j) => Book.fromJson(Map<String, dynamic>.from(j)),
        ),
      );
      for (final json in (data['recentBooks'] as List? ?? [])) {
        final book = Book.fromJson(Map<String, dynamic>.from(json));
        if (library.recentBooks.any((item) => item.key == book.key)) continue;
        library.recentBooks.add(book);
        if (library.recentBooks.length == recentBookLimit) break;
      }
      library.shelves.addAll(
        (data['shelves'] as List? ?? []).map(
          (j) => Bookshelf.fromJson(Map<String, dynamic>.from(j)),
        ),
      );
      library._pinnedBookKeys.addAll(
        (data['pinnedBookKeys'] as List? ?? []).whereType<String>(),
      );
      library.fontSize = (data['fontSize'] as num? ?? 20).toDouble().clamp(
        14,
        32,
      );
      library.themeMode =
          AppThemeMode.values
              .where((mode) => mode.name == data['themeMode'])
              .firstOrNull ??
          switch (data['night']) {
            true => AppThemeMode.dark,
            false => AppThemeMode.light,
            _ => AppThemeMode.system,
          };
      library.volumeKeyPaging = data['volumeKeyPaging'] != false;
      library.showParagraphComments = data['showParagraphComments'] != false;
      library.paragraphCommentPlacement = ParagraphCommentPlacement.values
          .firstWhere(
            (placement) => placement.name == data['paragraphCommentPlacement'],
            orElse: () => ParagraphCommentPlacement.right,
          );
      library._disabledSearchSources.addAll(
        (data['disabledSearchSources'] as List? ?? []).whereType<String>(),
      );
      library.shelfSort = ShelfSort.values.firstWhere(
        (sort) => sort.name == data['shelfSort'],
        orElse: () => ShelfSort.lastActive,
      );
      library.shelfLayout = ShelfLayout.values.firstWhere(
        (layout) => layout.name == data['shelfLayout'],
        orElse: () => ShelfLayout.grid,
      );
      for (final entry in (data['updatedTimes'] as Map? ?? {}).entries) {
        if (entry.value is num) {
          library.updatedTimes['${entry.key}'] = (entry.value as num).toInt();
        }
      }
      for (final entry in (data['lastActiveTimes'] as Map? ?? {}).entries) {
        if (entry.value is num) {
          library.lastActiveTimes['${entry.key}'] = (entry.value as num)
              .toInt();
        }
      }
      library.horizontalMargin = (data['horizontalMargin'] as num? ?? 22)
          .toDouble()
          .clamp(8, 64);
      library.verticalMargin = (data['verticalMargin'] as num? ?? 24)
          .toDouble()
          .clamp(8, 48);
      library.lineHeight = (data['lineHeight'] as num? ?? 1.9).toDouble().clamp(
        1.2,
        2.6,
      );
      library.readingFontId = data['readingFontId'] as String? ?? '';
      library.readingMode = data['readingMode'] == 'paged'
          ? ReadingMode.paged
          : ReadingMode.scroll;
      library.pageOffsets.addAll(
        (data['pageOffsets'] as Map? ?? {}).map(
          (key, value) => MapEntry('$key', (value as num).toInt()),
        ),
      );
      library.progress.addAll(
        (data['progress'] as Map? ?? {}).map(
          (k, v) => MapEntry('$k', (v as List).cast<int>()),
        ),
      );
      for (final entry in (data['pagedChapterEntries'] as Map? ?? {}).entries) {
        if (entry.value is List &&
            (entry.value as List).every((value) => value is int)) {
          library.pagedChapterEntries['${entry.key}'] = (entry.value as List)
              .cast<int>();
        }
      }
      if (!data.containsKey('recentBooks')) {
        final read =
            library.books
                .where((book) => library.progress[book.key]?.isNotEmpty == true)
                .toList()
              ..sort(
                (a, b) => (library.lastActiveTimes[b.key] ?? 0).compareTo(
                  library.lastActiveTimes[a.key] ?? 0,
                ),
              );
        library.recentBooks.addAll(read.take(recentBookLimit));
      }
    }
    library.downloadedFonts.addAll(await library.fonts.available());
    if (library.readingFontId.isNotEmpty) {
      try {
        library.readingFontFamily = await library.fonts.load(
          library.readingFontId,
        );
      } catch (_) {
        library.downloadedFonts.remove(library.readingFontId);
        library.fontNotice = '所选字体不可用，暂使用系统字体。可重新下载字体或选择系统字体。';
      }
    }
    return library;
  }

  Future<void> _atomic(File file, List<int> bytes) {
    final previous = _fileWrites[file.path] ?? Future<void>.value();
    late final Future<void> next;
    next = previous
        .catchError((_) {})
        .then(
          (_) => AppLog.instance.capture(
            'storage.write_failed',
            () => _replace(file, bytes),
          ),
        )
        .whenComplete(() {
          if (identical(_fileWrites[file.path], next)) {
            _fileWrites.remove(file.path);
          }
        });
    _fileWrites[file.path] = next;
    return next;
  }

  Future<void> _replace(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.${const Uuid().v4()}.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } finally {
      // A failed write must neither replace existing content nor leave a shared
      // temporary file that another request could rename.
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // Preserve the original write/rename failure for the caller.
      }
    }
  }

  Future<void> save() {
    final json = jsonEncode({
      'books': books.map((b) => b.toJson()).toList(),
      'recentBooks': recentBooks.map((b) => b.toJson()).toList(),
      'pinnedBookKeys': _pinnedBookKeys.toList(),
      'shelves': shelves.map((s) => s.toJson()).toList(),
      'progress': progress,
      'fontSize': fontSize,
      'themeMode': themeMode.name,
      // Keep the explicit dark preference readable by older app versions.
      'night': themeMode == AppThemeMode.dark,
      'readingMode': readingMode.name,
      'volumeKeyPaging': volumeKeyPaging,
      'showParagraphComments': showParagraphComments,
      'paragraphCommentPlacement': paragraphCommentPlacement.name,
      'disabledSearchSources': _disabledSearchSources.toList(),
      'pageOffsets': pageOffsets,
      'pagedChapterEntries': pagedChapterEntries,
      'readingFontId': readingFontId,
      'horizontalMargin': horizontalMargin,
      'verticalMargin': verticalMargin,
      'lineHeight': lineHeight,
      'shelfSort': shelfSort.name,
      'shelfLayout': shelfLayout.name,
      'updatedTimes': updatedTimes,
      'lastActiveTimes': lastActiveTimes,
    });
    // Serialize preferences writes so navigation and font changes cannot race.
    final next = _writes
        .catchError((_) {})
        .then(
          (_) => _atomic(File('${root.path}/index.json'), utf8.encode(json)),
        );
    _writes = next;
    notifyListeners();
    return next;
  }

  File _chapterFile(Book book, Chapter chapter) =>
      File('${root.path}/${safeKey(book.key)}/${safeKey(chapter.id)}.json');

  Future<void> setThemeMode(AppThemeMode mode) async {
    if (themeMode == mode) return;
    final previous = themeMode;
    themeMode = mode;
    try {
      await save();
    } catch (_) {
      themeMode = previous;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> selectFont(String id) async {
    String? family;
    try {
      family = id.isEmpty ? null : await fonts.load(id);
    } catch (_) {
      downloadedFonts.remove(id);
      notifyListeners();
      rethrow;
    }
    final oldId = readingFontId, oldFamily = readingFontFamily;
    readingFontId = id;
    readingFontFamily = family;
    fontNotice = null;
    try {
      await save();
    } catch (_) {
      readingFontId = oldId;
      readingFontFamily = oldFamily;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> downloadFont(
    String id, {
    void Function(int, int?)? onProgress,
  }) async {
    await fonts.download(id, onProgress: onProgress);
    downloadedFonts.add(id);
    await selectFont(id);
  }

  Future<void> resetReadingPreferences() async {
    readingFontId = '';
    readingFontFamily = null;
    fontNotice = null;
    fontSize = 20;
    horizontalMargin = 22;
    verticalMargin = 24;
    lineHeight = 1.9;
    readingMode = ReadingMode.scroll;
    volumeKeyPaging = true;
    showParagraphComments = true;
    paragraphCommentPlacement = ParagraphCommentPlacement.right;
    await save();
  }

  Future<void> add(Book book) async {
    final previous = books.where((item) => item.key == book.key).firstOrNull;
    final oldUpdated = updatedTimes[book.key];
    final oldActive = lastActiveTimes[book.key];
    final now = clock().millisecondsSinceEpoch;
    if (book.source == 'local') {
      updatedTimes[book.key] = now;
    } else if (book.updatedAt != null) {
      updatedTimes[book.key] = book.updatedAt!.millisecondsSinceEpoch;
    } else {
      updatedTimes.putIfAbsent(book.key, () => 0);
    }
    lastActiveTimes.putIfAbsent(book.key, () => now);
    final index = books.indexWhere((b) => b.key == book.key);
    if (index < 0) {
      books.insert(0, book);
    } else {
      books[index] = book;
    }
    try {
      await save();
    } catch (_) {
      final current = books.indexWhere((item) => item.key == book.key);
      if (current >= 0 && identical(books[current], book)) {
        if (previous == null) {
          books.removeAt(current);
        } else {
          books[current] = previous;
        }
      }
      if (oldUpdated == null) {
        updatedTimes.remove(book.key);
      } else {
        updatedTimes[book.key] = oldUpdated;
      }
      if (oldActive == null) {
        lastActiveTimes.remove(book.key);
      } else {
        lastActiveTimes[book.key] = oldActive;
      }
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateBook(Book book) async {
    final shelfIndex = books.indexWhere((item) => item.key == book.key);
    final recentIndex = recentBooks.indexWhere((item) => item.key == book.key);
    final oldShelf = shelfIndex < 0 ? null : books[shelfIndex];
    final oldRecent = recentIndex < 0 ? null : recentBooks[recentIndex];
    final oldUpdated = updatedTimes[book.key];
    if (shelfIndex >= 0) books[shelfIndex] = book;
    if (recentIndex >= 0) recentBooks[recentIndex] = book;
    if (book.updatedAt != null) {
      updatedTimes[book.key] = book.updatedAt!.millisecondsSinceEpoch;
    }
    try {
      await save();
    } catch (_) {
      final shelf = books.indexWhere((item) => item.key == book.key);
      final recent = recentBooks.indexWhere((item) => item.key == book.key);
      if (shelf >= 0 && oldShelf != null && identical(books[shelf], book)) {
        books[shelf] = oldShelf;
      }
      if (recent >= 0 &&
          oldRecent != null &&
          identical(recentBooks[recent], book)) {
        recentBooks[recent] = oldRecent;
      }
      if (oldUpdated == null) {
        updatedTimes.remove(book.key);
      } else {
        updatedTimes[book.key] = oldUpdated;
      }
      notifyListeners();
      rethrow;
    }
  }

  Future<Bookshelf> importShelf({
    required String name,
    required BookshelfSource source,
    required RemoteBookshelf remote,
    required List<Book> imported,
  }) async {
    final label = name.trim();
    if (label.isEmpty) throw const SourceException('请填写书架名称');
    if (shelves.any((s) => s.name == label) ||
        label == '全部作品' ||
        label == '最近阅读') {
      throw const SourceException('书架名称已存在，请使用其他名称');
    }
    if (imported.any((b) => b.source != source.id)) {
      throw const SourceException('导入作品的平台与书架不一致');
    }
    final oldBooks = books.toList();
    final oldUpdated = Map<String, int>.from(updatedTimes);
    final oldActive = Map<String, int>.from(lastActiveTimes);
    final shelf = Bookshelf(
      id: const Uuid().v4(),
      name: label,
      source: source.id,
      remoteId: remote.id,
      bookKeys: imported.map((b) => b.key).toSet().toList(),
    );
    final now = clock().millisecondsSinceEpoch;
    for (final book in imported) {
      // Reuse an existing book so its cached directory and reading positions
      // remain aligned. Refreshing that book is a separate reader action.
      if (books.any((b) => b.key == book.key)) continue;
      books.add(book);
      updatedTimes[book.key] = book.updatedAt?.millisecondsSinceEpoch ?? 0;
      lastActiveTimes[book.key] = now;
    }
    shelves.add(shelf);
    try {
      await save();
    } catch (_) {
      shelves.remove(shelf);
      books
        ..clear()
        ..addAll(oldBooks);
      updatedTimes
        ..clear()
        ..addAll(oldUpdated);
      lastActiveTimes
        ..clear()
        ..addAll(oldActive);
      notifyListeners();
      rethrow;
    }
    return shelf;
  }

  Future<void> setShelfSort(ShelfSort sort) async {
    final old = shelfSort;
    shelfSort = sort;
    try {
      await save();
    } catch (_) {
      shelfSort = old;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setBookPinned(Book book, bool pinned) async {
    final wasPinned = isBookPinned(book);
    if (wasPinned == pinned) return;
    if (pinned) {
      _pinnedBookKeys.add(book.key);
    } else {
      _pinnedBookKeys.remove(book.key);
    }
    try {
      await save();
    } catch (_) {
      if (wasPinned) {
        _pinnedBookKeys.add(book.key);
      } else {
        _pinnedBookKeys.remove(book.key);
      }
      notifyListeners();
      rethrow;
    }
  }

  Future<void> removeFromShelf(Book book, {String? shelfId}) async {
    final oldBooks = books.toList();
    final oldRecent = recentBooks.toList();
    final oldShelves = shelves.toList();
    final wasPinned = isBookPinned(book);
    if (shelfId == recentShelfId) {
      recentBooks.removeWhere((item) => item.key == book.key);
    } else {
      if (shelfId == null) {
        books.removeWhere((item) => item.key == book.key);
      } else if (!shelves.any((shelf) => shelf.id == shelfId)) {
        throw const SourceException('当前书架不存在');
      }
      for (var i = 0; i < shelves.length; i++) {
        final shelf = shelves[i];
        if ((shelfId == null || shelf.id == shelfId) &&
            shelf.bookKeys.contains(book.key)) {
          shelves[i] = shelf.copyWith(
            bookKeys: shelf.bookKeys.where((key) => key != book.key).toList(),
          );
        }
      }
    }
    if (!isOnShelf(book) && !recentBooks.any((item) => item.key == book.key)) {
      _pinnedBookKeys.remove(book.key);
    }
    try {
      await save();
    } catch (_) {
      books
        ..clear()
        ..addAll(oldBooks);
      recentBooks
        ..clear()
        ..addAll(oldRecent);
      shelves
        ..clear()
        ..addAll(oldShelves);
      if (wasPinned) _pinnedBookKeys.add(book.key);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setSearchSourceEnabled(String id, bool enabled) async {
    final wasEnabled = isSearchSourceEnabled(id);
    if (enabled == wasEnabled) return;
    if (enabled) {
      _disabledSearchSources.remove(id);
    } else {
      _disabledSearchSources.add(id);
    }
    try {
      await save();
    } catch (_) {
      if (wasEnabled) {
        _disabledSearchSources.remove(id);
      } else {
        _disabledSearchSources.add(id);
      }
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setShelfLayout(ShelfLayout layout) async {
    final old = shelfLayout;
    shelfLayout = layout;
    try {
      await save();
    } catch (_) {
      shelfLayout = old;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> markActive(Book book) async {
    lastActiveTimes[book.key] = clock().millisecondsSinceEpoch;
    await save();
  }

  Future<void> recordReading(Book book) async {
    final oldActive = lastActiveTimes[book.key];
    final oldRecent = recentBooks.toList();
    lastActiveTimes[book.key] = clock().millisecondsSinceEpoch;
    recentBooks.removeWhere((item) => item.key == book.key);
    recentBooks.insert(0, book);
    if (recentBooks.length > recentBookLimit) {
      recentBooks.removeRange(recentBookLimit, recentBooks.length);
    }
    try {
      await save();
    } catch (_) {
      recentBooks
        ..clear()
        ..addAll(oldRecent);
      if (oldActive == null) {
        lastActiveTimes.remove(book.key);
      } else {
        lastActiveTimes[book.key] = oldActive;
      }
      notifyListeners();
      rethrow;
    }
  }

  Future<void> store(Book book, Chapter chapter, ChapterContent content) =>
      _atomic(
        _chapterFile(book, chapter),
        utf8.encode(jsonEncode(content.toJson())),
      );
  Future<ChapterContent?> cached(Book book, Chapter chapter) async {
    final file = _chapterFile(book, chapter);
    if (!await file.exists()) return null;
    return ChapterContent.fromJson(jsonDecode(await file.readAsString()));
  }

  Future<ChapterContent> read(Book book, Chapter chapter) {
    final key = '${book.key}/${chapter.id}';
    return _reads.putIfAbsent(key, () {
      return _readChapter(book, chapter).whenComplete(() {
        _reads.remove(key);
      });
    });
  }

  Future<ChapterContent> _readChapter(Book book, Chapter chapter) =>
      AppLog.instance.capture('reader.chapter_failed', () async {
        final saved = await cached(book, chapter);
        if (saved != null) return saved;
        final service = sourceFor(book);
        if (service == null) {
          throw SourceException(
            book.source == 'local' ? '本地章节缓存缺失，请重新导入原文件' : '当前书源不可用，已缓存章节仍可阅读',
          );
        }
        final content = await service.readChapter(book, chapter);
        await store(book, chapter, content);
        return content;
      });

  Future<Map<String, ChapterContent>> cachedContents(Book book) async {
    final result = <String, ChapterContent>{};
    for (final chapter in book.chapters) {
      final c = await cached(book, chapter);
      if (c != null) result[chapter.id] = c;
    }
    return result;
  }

  File imageFile(Book book, String key) =>
      File('${root.path}/${safeKey(book.key)}/images/${safeKey(key)}');
  Future<Uint8List?> image(Book book, String key) async {
    final file = imageFile(book, key);
    return await file.exists() ? file.readAsBytes() : null;
  }

  Future<void> saveImage(Book book, String key, Uint8List bytes) =>
      _atomic(imageFile(book, key), bytes);
  Future<Uint8List> loadImage(Book book, String key) {
    final requestKey = '${book.key}/$key';
    return _imageReads.putIfAbsent(requestKey, () {
      return _loadImage(book, key).whenComplete(() {
        _imageReads.remove(requestKey);
      });
    });
  }

  Future<Uint8List> _loadImage(Book book, String key) =>
      AppLog.instance.capture('reader.image_failed', () async {
        final saved = await image(book, key);
        if (saved != null) return saved;
        if (key.startsWith('local:')) {
          throw const SourceException('本地插图缺失，请重新导入原文件');
        }
        var uri = Uri.parse(key);
        if (uri.scheme == 'http') uri = uri.replace(scheme: 'https');
        if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
          throw const SourceException('插图地址无效');
        }
        final response = await source.api.client
            .send(http.Request('GET', uri))
            .timeout(const Duration(seconds: 25));
        if (response.statusCode != 200) {
          throw SourceException('插图下载失败（HTTP ${response.statusCode}）');
        }
        final builder = BytesBuilder();
        await for (final bytes in response.stream.timeout(
          const Duration(seconds: 25),
        )) {
          builder.add(bytes);
          if (builder.length > 20 * 1024 * 1024) {
            throw const SourceException('单张插图超过 20 MB');
          }
        }
        final data = builder.takeBytes();
        await saveImage(book, key, data);
        return data;
      });

  Future<void> cacheImages(Book book, ChapterContent content) async {
    for (final p in content.paragraphs) {
      if (p.image != null) await loadImage(book, p.image!);
    }
    // EPUB export also needs the cover, even if its preview was never opened.
    if (book.cover.isNotEmpty) await loadImage(book, book.cover);
  }

  Future<void> import(ImportedBook data) async {
    for (final chapter in data.book.chapters) {
      await store(data.book, chapter, data.contents[chapter.id]!);
    }
    for (final entry in data.images.entries) {
      await saveImage(data.book, entry.key, entry.value);
    }
    await add(data.book);
  }

  Future<void> remember(Book book, int chapter, int paragraph) async {
    progress[book.key] = [chapter, paragraph];
    lastActiveTimes[book.key] = clock().millisecondsSinceEpoch;
    await save();
  }
}
