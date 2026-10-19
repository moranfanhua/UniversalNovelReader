import 'dart:async';
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
import '../sources/source_order.dart';
import '../domain/reading_preferences.dart';
import '../domain/bookshelf.dart';
import '../sources/bookshelf_source.dart';
import '../sources/chapter_batch_source.dart';
import '../sources/sfacg/sfacg_source.dart';
import '../sources/comment_source.dart';
import '../sources/novel_source.dart';
import 'reader_fonts.dart';
import 'download_mirror.dart';
import 'app_log.dart';
import 'library_snapshot.dart';

enum ReadingMode { scroll, paged }

enum AppThemeMode { system, light, dark }

enum ShelfSort { updated, name, lastActive }

enum ShelfLayout { grid, list }

class ShelfUpdateResult {
  const ShelfUpdateResult({this.checked = 0, this.failed = 0});
  final int checked, failed;
}

class DownloadedBook {
  const DownloadedBook({required this.book, required this.chapterIds});
  final Book book;
  final Set<String> chapterIds;
}

class DownloadedBooksSnapshot {
  const DownloadedBooksSnapshot({required this.books, this.unreadable = 0});
  final List<DownloadedBook> books;
  final int unreadable;
}

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
  List<SearchableNovelSource> get searchSources => platformDisplayOrder(
    _novelSources.values.whereType<SearchableNovelSource>(),
  );
  final Set<String> _disabledSearchSources = {};
  bool isSearchSourceEnabled(String id) => !_disabledSearchSources.contains(id);
  List<SearchableNovelSource> get enabledSearchSources => searchSources
      .where((source) => isSearchSourceEnabled(source.id))
      .toList();
  List<BookshelfSource> get bookshelfSources =>
      platformDisplayOrder(_novelSources.values.whereType<BookshelfSource>());
  String sourceName(Book book) =>
      sourceFor(book)?.name ?? (book.source == 'local' ? '本地小说' : '未知书源');
  final Map<String, CommentSource> _commentSources;
  CommentSource? commentsFor(Book book) => _commentSources[book.source];
  final DateTime Function() clock;
  final ReaderFonts fonts;
  DownloadMirror _downloadMirror = DownloadMirror.defaults;
  DownloadMirror get downloadMirror => _downloadMirror;
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
  static const shelfUpdateInterval = Duration(minutes: 10);
  final Map<String, int> _shelfUpdateTimes = {};
  Future<void>? _shelfUpdates;
  bool _disposed = false;
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
  PageTurnAnimation pageTurnAnimation = PageTurnAnimation.slide;
  bool volumeKeyPaging = true;
  bool showParagraphComments = true;
  ParagraphCommentPlacement paragraphCommentPlacement =
      ParagraphCommentPlacement.right;
  final Map<String, int> pageOffsets = {};
  // Entry alignment and preceding spread origin, indexed by book and chapter.
  // Values: [skipFirstPage, precedingChapterIndex, precedingSkipFirstPage].
  final Map<String, List<int>> pagedChapterEntries = {};
  String readingFontId = '';
  String? readingFontFamily, fontNotice;
  final downloadedFonts = <String>{};
  double horizontalMargin = 22, verticalMargin = 24, lineHeight = 1.9;
  Future<void> _writes = Future.value();
  final _bookJson = Expando<String>();
  final Map<String, Future<ChapterContent>> _reads = {};
  final Map<String, Future<Uint8List>> _imageReads = {};
  final Map<String, Future<void>> _fileWrites = {};
  final _cachedBookMetadata = <String, ({Book book, Future<void> write})>{};
  final _deletingBooks = <String>{};
  final _cacheRevisions = <String, int>{};
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
      library._downloadMirror = DownloadMirror.fromJson(data['downloadMirror']);
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
      for (final entry in (data['shelfUpdateTimes'] as Map? ?? {}).entries) {
        if (entry.value is int) {
          library._shelfUpdateTimes['${entry.key}'] = entry.value;
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
      library.pageTurnAnimation = PageTurnAnimation.values.firstWhere(
        (animation) => animation.name == data['pageTurnAnimation'],
        orElse: () => PageTurnAnimation.slide,
      );
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
    // Freeze mutable state when requested, before queued writes or background
    // encoding can yield to reading, settings changes, or another update.
    final savedBooks = books.toList();
    final savedRecentBooks = recentBooks.toList();
    final preferences = <String, Object?>{
      'pinnedBookKeys': _pinnedBookKeys.toList(),
      'shelves': shelves
          .map((s) => {...s.toJson(), 'bookKeys': s.bookKeys.toList()})
          .toList(),
      'progress': {
        for (final entry in progress.entries) entry.key: entry.value.toList(),
      },
      'fontSize': fontSize,
      'themeMode': themeMode.name,
      // Keep the explicit dark preference readable by older app versions.
      'night': themeMode == AppThemeMode.dark,
      'readingMode': readingMode.name,
      'pageTurnAnimation': pageTurnAnimation.name,
      'volumeKeyPaging': volumeKeyPaging,
      'showParagraphComments': showParagraphComments,
      'paragraphCommentPlacement': paragraphCommentPlacement.name,
      'disabledSearchSources': _disabledSearchSources.toList(),
      'downloadMirror': _downloadMirror.toJson(),
      'pageOffsets': Map<String, int>.of(pageOffsets),
      'pagedChapterEntries': {
        for (final entry in pagedChapterEntries.entries)
          entry.key: entry.value.toList(),
      },
      'readingFontId': readingFontId,
      'horizontalMargin': horizontalMargin,
      'verticalMargin': verticalMargin,
      'lineHeight': lineHeight,
      'shelfSort': shelfSort.name,
      'shelfLayout': shelfLayout.name,
      'updatedTimes': Map<String, int>.of(updatedTimes),
      'lastActiveTimes': Map<String, int>.of(lastActiveTimes),
      'shelfUpdateTimes': Map<String, int>.of(_shelfUpdateTimes),
    };
    // Serialize encoding as well as replacement, so older snapshots cannot
    // overwrite newer preferences and only one full index is built at a time.
    final next = _writes.catchError((_) {}).then((_) async {
      final missing = <Book>[];
      Object cachedBook(Book book) {
        final json = _bookJson[book];
        if (json != null) return json;
        missing.add(book);
        return book;
      }

      final snapshot = (
        preferences: preferences,
        books: savedBooks.map(cachedBook).toList(),
        recentBooks: savedRecentBooks.map(cachedBook).toList(),
      );
      final encoded = await compute(
        encodeLibrarySnapshot,
        snapshot,
        debugLabel: 'library.encode',
      );
      for (var i = 0; i < missing.length; i++) {
        _bookJson[missing[i]] = encoded.newBooks[i];
      }
      await _atomic(File('${root.path}/index.json'), encoded.bytes);
    });
    _writes = next;
    if (!_disposed) notifyListeners();
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
    await fonts.download(id, mirror: downloadMirror, onProgress: onProgress);
    downloadedFonts.add(id);
    await selectFont(id);
  }

  Future<void> setDownloadMirror(DownloadMirror value) async {
    if (downloadMirror.enabled == value.enabled &&
        downloadMirror.baseUrl == value.baseUrl) {
      return;
    }
    final previous = _downloadMirror;
    _downloadMirror = value;
    try {
      await save();
    } catch (_) {
      if (identical(_downloadMirror, value)) _downloadMirror = previous;
      notifyListeners();
      rethrow;
    }
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
    pageTurnAnimation = PageTurnAnimation.slide;
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

  Future<void> updateBook(Book book, {bool preserveChapterPosition = false}) =>
      _updateBook(book, preserveChapterPosition: preserveChapterPosition);

  Future<void> _updateBook(
    Book book, {
    bool preserveChapterPosition = false,
    Future<void> Function()? persist,
  }) async {
    final shelfIndex = books.indexWhere((item) => item.key == book.key);
    final recentIndex = recentBooks.indexWhere((item) => item.key == book.key);
    final oldShelf = shelfIndex < 0 ? null : books[shelfIndex];
    final oldRecent = recentIndex < 0 ? null : recentBooks[recentIndex];
    final oldUpdated = updatedTimes[book.key];
    final previous = oldShelf ?? oldRecent;
    final oldProgress = progress[book.key];
    List<int>? nextProgress;
    final oldEntries = <String, List<int>>{};
    final nextEntries = <String, List<int>>{};
    if (preserveChapterPosition &&
        previous != null &&
        !identical(previous.chapters, book.chapters)) {
      final indices = {
        for (var i = 0; i < book.chapters.length; i++) book.chapters[i].id: i,
      };
      if (oldProgress != null &&
          oldProgress.isNotEmpty &&
          oldProgress.first >= 0 &&
          oldProgress.first < previous.chapters.length) {
        final index = indices[previous.chapters[oldProgress.first].id];
        if (index == null) {
          throw const SourceException('当前阅读章节不在新目录中，已保留原目录，请手动检查');
        }
        if (index != oldProgress.first) {
          nextProgress = [index, ...oldProgress.skip(1)];
        }
      }
      for (final entry in pagedChapterEntries.entries) {
        if (!entry.key.startsWith('${book.key}:')) continue;
        oldEntries[entry.key] = entry.value;
        final index = int.tryParse(entry.key.substring(book.key.length + 1));
        if (index == null || index < 0 || index >= previous.chapters.length) {
          continue;
        }
        final next = indices[previous.chapters[index].id];
        if (next == null) continue;
        var migrated = List<int>.of(entry.value);
        if (migrated.length >= 3) {
          final origin = migrated[1];
          final nextOrigin = origin >= 0 && origin < index
              ? indices[previous.chapters[origin].id]
              : null;
          var sameSpan = false;
          if (nextOrigin != null && next - nextOrigin == index - origin) {
            sameSpan = true;
            for (var offset = 0; offset <= index - origin; offset++) {
              if (previous.chapters[origin + offset].id !=
                  book.chapters[nextOrigin + offset].id) {
                sameSpan = false;
                break;
              }
            }
          }
          if (sameSpan) {
            migrated[1] = nextOrigin!;
          } else {
            // The old spread may have shown a page from a removed or moved
            // chapter. Reset its alignment and use the new directory order.
            migrated = [0];
          }
        }
        nextEntries['${book.key}:$next'] = migrated;
      }
    }
    if (nextProgress != null) progress[book.key] = nextProgress;
    for (final key in oldEntries.keys) {
      pagedChapterEntries.remove(key);
    }
    pagedChapterEntries.addAll(nextEntries);
    if (shelfIndex >= 0) books[shelfIndex] = book;
    if (recentIndex >= 0) recentBooks[recentIndex] = book;
    if (book.updatedAt != null) {
      updatedTimes[book.key] = book.updatedAt!.millisecondsSinceEpoch;
    }
    try {
      await (persist ?? save)();
    } catch (_) {
      final shelf = books.indexWhere((item) => item.key == book.key);
      final recent = recentBooks.indexWhere((item) => item.key == book.key);
      if ((oldShelf != null || oldRecent != null) &&
          !(shelf >= 0 && identical(books[shelf], book)) &&
          !(recent >= 0 && identical(recentBooks[recent], book))) {
        // A manual refresh or removal may have won while a shared checkpoint
        // was pending. Its metadata and migrated positions belong to that edit.
        rethrow;
      }
      if (nextProgress != null && identical(progress[book.key], nextProgress)) {
        progress[book.key] = oldProgress!;
      }
      for (final key in {...oldEntries.keys, ...nextEntries.keys}) {
        if (!identical(pagedChapterEntries[key], nextEntries[key])) continue;
        final old = oldEntries[key];
        if (old == null) {
          pagedChapterEntries.remove(key);
        } else {
          pagedChapterEntries[key] = old;
        }
      }
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
      if (!_disposed) notifyListeners();
      rethrow;
    }
  }

  /// Visits share a per-book cooldown, including failed attempts and restarts.
  /// Queued visits and workers stop when their shelf is no longer visible.
  Future<ShelfUpdateResult> refreshShelfBooks({
    String? shelfId,
    required bool Function() isCancelled,
  }) {
    Future<ShelfUpdateResult> run() async {
      bool cancelled() => _disposed || isCancelled();
      if (cancelled()) return const ShelfUpdateResult();
      final keys = shelfId == null || shelfId == recentShelfId
          ? null
          : shelves.where((shelf) => shelf.id == shelfId).firstOrNull?.bookKeys;
      if (shelfId != null && shelfId != recentShelfId && keys == null) {
        return const ShelfUpdateResult();
      }
      final candidates = (shelfId == recentShelfId ? recentBooks : books)
          .where((book) => keys == null || keys.contains(book.key))
          .where((book) => book.source != 'local' && sourceFor(book) != null)
          .toList();
      // Each of the three workers awaits its checkpoint. Sharing checkpoints
      // batches their writes without allowing an unbounded queue or delaying
      // persistence beyond 250 ms when a request is slow or fails.
      final checkpoints = _ShelfCheckpoints(
        save,
        batchSize: candidates.length < 3 ? candidates.length : 3,
      );
      var cursor = 0, checked = 0, failed = 0;
      Book? current(String key) =>
          (shelfId == recentShelfId ? recentBooks : books)
              .where((book) => book.key == key)
              .firstOrNull;
      Future<void> worker() async {
        while (!cancelled() && cursor < candidates.length) {
          final book = candidates[cursor++];
          if (!identical(current(book.key), book)) continue;
          final now = clock().millisecondsSinceEpoch;
          final last = _shelfUpdateTimes[book.key];
          if (last != null && now - last < shelfUpdateInterval.inMilliseconds) {
            continue;
          }
          _shelfUpdateTimes[book.key] = now;
          checked++;
          try {
            // Persist before sending, so reopening cannot bypass the cooldown.
            await checkpoints.save();
            if (cancelled()) return;
            final service = sourceFor(book)!;
            Book next;
            if (service is BookUpdateSource) {
              final preview = await service.getBookUpdate(book.id);
              if (cancelled() || !identical(current(book.key), book)) continue;
              if (preview.key != book.key) {
                throw const SourceException('书源未返回对应作品的信息，已保留本地内容');
              }
              final changed =
                  preview.updatedAt == null ||
                  book.updatedAt == null ||
                  preview.updatedAt != book.updatedAt ||
                  (preview.wordCount != null &&
                      book.wordCount != null &&
                      preview.wordCount != book.wordCount);
              if (preview.chapters.isNotEmpty) {
                next = preview;
              } else if (book.chapters.isNotEmpty && changed) {
                next = await service.getBook(book.id);
                if (next.chapters.isEmpty) {
                  throw const SourceException('书源未返回完整目录，已保留本地内容');
                }
              } else {
                // Newly imported books stay lazy. Fresh timestamps still drive
                // shelf sorting; an unchanged cached directory remains usable.
                next = preview.withChapters(book.chapters);
              }
            } else {
              next = await service.getBook(book.id);
              if (next.chapters.isEmpty) {
                throw const SourceException('书源未返回完整目录，已保留本地内容');
              }
            }
            if (cancelled() || !identical(current(book.key), book)) continue;
            if (next.key != book.key) {
              throw const SourceException('书源未返回对应作品的信息，已保留本地内容');
            }
            await _updateBook(
              next,
              preserveChapterPosition: true,
              persist: checkpoints.save,
            );
          } catch (error, stack) {
            if (cancelled()) return;
            failed++;
            AppLog.instance.record(
              LogLevel.warning,
              'bookshelf.update_failed',
              error: error,
              stackTrace: stack,
            );
          }
        }
      }

      await Future.wait(List.generate(3, (_) => worker()));
      return ShelfUpdateResult(checked: checked, failed: failed);
    }

    final previous = _shelfUpdates;
    final next = previous == null
        ? Future<ShelfUpdateResult>.sync(run)
        : previous.then((_) => run());
    late final Future<void> tail;
    void finished() {
      if (identical(_shelfUpdates, tail)) _shelfUpdates = null;
    }

    tail = next.then<void>(
      (_) => finished(),
      onError: (Object _, StackTrace _) => finished(),
    );
    _shelfUpdates = tail;
    return next;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
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

  Future<void> _storeCachedBook(Book book) {
    _checkCacheAvailable(book);
    final previous = _cachedBookMetadata[book.key];
    if (identical(previous?.book, book)) return previous!.write;
    final write = _atomic(
      File('${root.path}/${safeKey(book.key)}/book.json'),
      utf8.encode(jsonEncode(book.toJson())),
    );
    _cachedBookMetadata[book.key] = (book: book, write: write);
    unawaited(
      write.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_cachedBookMetadata[book.key]?.write, write)) {
            _cachedBookMetadata.remove(book.key);
          }
        },
      ),
    );
    return write;
  }

  Future<void> store(Book book, Chapter chapter, ChapterContent content) async {
    // Keep metadata with the cache so downloads survive removal from shelves
    // and eviction from the bounded reading history, without adding shelf books.
    await _storeCachedBook(book);
    _checkCacheAvailable(book);
    await _atomic(
      _chapterFile(book, chapter),
      utf8.encode(jsonEncode(content.toJson())),
    );
  }

  Future<DownloadedBooksSnapshot> downloadedBooks() async {
    final candidates = {
      for (final book in [...recentBooks, ...books]) book.key: book,
    };
    final metadata = <String, Book>{};
    var unreadable = 0;
    if (await root.exists()) {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final file = File('${entity.path}/book.json');
        try {
          if (!await file.exists()) continue;
          final book = Book.fromJson(jsonDecode(await file.readAsString()));
          if (file.parent.uri !=
              Directory('${root.path}/${safeKey(book.key)}').uri) {
            throw const FormatException('下载记录与缓存目录不匹配');
          }
          metadata[book.key] = book;
          final current = candidates[book.key];
          // A shelf preview can lack a directory; retain the cached full one.
          if (current == null || current.chapters.isEmpty) {
            candidates[book.key] = book;
          }
        } catch (_) {
          unreadable++;
        }
      }
    }
    final downloaded = <DownloadedBook>[];
    for (final book in candidates.values) {
      try {
        final directory = Directory('${root.path}/${safeKey(book.key)}');
        if (!await directory.exists()) continue;
        final files = <String>{};
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is File) files.add(entity.uri.pathSegments.last);
        }
        final ids = {
          for (final chapter in book.chapters)
            if (files.contains('${safeKey(chapter.id)}.json')) chapter.id,
        };
        if (ids.isEmpty) continue;
        downloaded.add(DownloadedBook(book: book, chapterIds: ids));
        // Older caches have only shelf/history metadata. Migrate it in place.
        if (!identical(metadata[book.key], book)) {
          await _storeCachedBook(book);
        }
      } catch (_) {
        unreadable++;
      }
    }
    return DownloadedBooksSnapshot(books: downloaded, unreadable: unreadable);
  }

  Future<ChapterContent?> cached(Book book, Chapter chapter) async {
    final file = _chapterFile(book, chapter);
    if (!await file.exists()) return null;
    return ChapterContent.fromJson(jsonDecode(await file.readAsString()));
  }

  Future<ChapterContent> read(Book book, Chapter chapter) async {
    _checkCacheAvailable(book);
    final revision = _cacheRevisions[book.key] ?? 0;
    // An explicit cache refresh must not block reading the existing chapter,
    // or make a failed refresh prevent offline reading.
    final saved = await AppLog.instance.capture(
      'reader.chapter_failed',
      () => cached(book, chapter),
    );
    _checkCacheAvailable(book);
    if (revision != (_cacheRevisions[book.key] ?? 0)) {
      throw const SourceException('本书缓存已变化，请重新打开阅读');
    }
    if (saved != null) return saved;
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

  final _downloads = <String>{};

  void _checkCacheAvailable(Book book) {
    if (_deletingBooks.contains(book.key)) {
      throw const SourceException('本书缓存正在删除，请稍后重试');
    }
  }

  Future<void> deleteDownloadedBook(Book book) async {
    if (!_deletingBooks.add(book.key)) {
      throw const SourceException('本书缓存正在删除，请稍后重试');
    }
    try {
      final directory = Directory('${root.path}/${safeKey(book.key)}');
      final prefix = directory.absolute.uri.toString();
      if (_downloads.contains(book.key) ||
          _reads.keys.any((key) => key.startsWith('${book.key}/')) ||
          _imageReads.keys.any((key) => key.startsWith('${book.key}/')) ||
          _fileWrites.keys.any(
            (path) => File(path).absolute.uri.toString().startsWith(prefix),
          )) {
        throw const SourceException('本书正在读取或下载，请等待完成后重试删除');
      }
      _cacheRevisions[book.key] = (_cacheRevisions[book.key] ?? 0) + 1;
      final type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) return;
      if (type != FileSystemEntityType.directory) {
        throw const SourceException('缓存目录类型异常，未执行删除');
      }
      final resolvedRoot = Directory(await root.resolveSymbolicLinks());
      final resolvedDirectory = Directory(
        await directory.resolveSymbolicLinks(),
      );
      if (resolvedDirectory.parent.uri != resolvedRoot.uri) {
        throw const SourceException('缓存目录位置异常，未执行删除');
      }
      await directory.delete(recursive: true);
    } finally {
      // Even a partial filesystem failure must allow later downloads to rebuild
      // metadata. Shelf membership, reading history and progress stay untouched.
      _cachedBookMetadata.remove(book.key);
      _deletingBooks.remove(book.key);
    }
  }

  Future<void> downloadChapters(
    Book book,
    List<Chapter> chapters, {
    required void Function(Chapter chapter, Object? error) onProgress,
    bool Function()? isCancelled,
    bool refreshCached = false,
  }) async {
    _checkCacheAvailable(book);
    if (!_downloads.add(book.key)) {
      throw const SourceException('本书已有下载任务，请等待完成或停止后重试');
    }
    try {
      final service = sourceFor(book);
      final batchSource = service is ChapterBatchSource ? service : null;
      final size = batchSource?.chapterBatchSize ?? 1;
      final concurrency = batchSource?.chapterBatchConcurrency ?? 1;
      if (size < 1) throw StateError('书源下载批量大小无效');
      if (concurrency < 1) throw StateError('书源下载并发数量无效');
      final selected = <String, Chapter>{};
      final directory = {for (final chapter in book.chapters) chapter.id};
      for (final chapter in chapters) {
        if (!directory.contains(chapter.id)) {
          throw const SourceException('下载章节不属于当前作品');
        }
        selected[chapter.id] = chapter;
      }
      final queue = selected.values.toList();
      var offset = 0;
      Future<void> worker() async {
        while (offset < queue.length && isCancelled?.call() != true) {
          final batch = queue.sublist(
            offset,
            (offset + size).clamp(0, queue.length),
          );
          offset += batch.length;
          final results = await _downloadBatch(
            book,
            batch,
            service,
            refreshCached: refreshCached,
          );
          for (var i = 0; i < batch.length; i++) {
            var error = results[i].error;
            if (error == null && !refreshCached) {
              try {
                await cacheImages(book, results[i].content!);
              } catch (reason) {
                error = reason;
              }
            }
            onProgress(batch[i], error);
          }
        }
      }

      // Active batches finish caching; cancellation prevents scheduling more.
      await Future.wait(List.generate(concurrency, (_) => worker()));
    } finally {
      _downloads.remove(book.key);
    }
  }

  Future<List<ChapterBatchResult>> _downloadBatch(
    Book book,
    List<Chapter> chapters,
    NovelSource? service, {
    bool refreshCached = false,
  }) async {
    final owned = <Chapter, Completer<ChapterContent>>{};
    final waiting = <Future<ChapterBatchResult>>[];
    for (final chapter in chapters) {
      final key = '${book.key}/${chapter.id}';
      var reading = _reads[key];
      if (refreshCached) {
        // Finish any earlier read before refetching so it cannot overwrite
        // the refreshed cache later. A cached read is never a refresh result.
        while (reading != null) {
          await reading.then<void>((_) {}, onError: (Object _) {});
          if (identical(_reads[key], reading)) _reads.remove(key);
          reading = _reads[key];
        }
      }
      if (reading == null) {
        final completer = Completer<ChapterContent>();
        owned[chapter] = completer;
        reading = completer.future;
        _reads[key] = reading;
        void release() {
          if (identical(_reads[key], reading)) _reads.remove(key);
        }

        unawaited(
          reading.then((_) => release(), onError: (Object _) => release()),
        );
      }
      waiting.add(
        reading.then(
          (content) => ChapterBatchResult.success(chapter.id, content),
          onError: (Object error) =>
              ChapterBatchResult.failure(chapter.id, error),
        ),
      );
    }
    try {
      final missing = <Chapter>[];
      for (final entry in owned.entries) {
        try {
          final saved = await cached(book, entry.key);
          if (saved == null || refreshCached) {
            missing.add(entry.key);
          } else {
            entry.value.complete(saved);
          }
        } catch (error, stack) {
          entry.value.completeError(error, stack);
        }
      }
      if (missing.isNotEmpty) {
        if (service == null) throw const SourceException('当前书源不可用，已缓存章节仍可阅读');
        final results = service is ChapterBatchSource
            ? await service.readChapterBatch(book, missing)
            : [
                ChapterBatchResult.success(
                  missing.single.id,
                  await service.readChapter(book, missing.single),
                ),
              ];
        final byId = <String, ChapterBatchResult>{};
        final requested = missing.map((chapter) => chapter.id).toSet();
        for (final result in results) {
          if (!requested.contains(result.id) || byId.containsKey(result.id)) {
            throw const SourceException('书源批量下载返回了不匹配或重复的章节');
          }
          byId[result.id] = result;
        }
        for (final chapter in missing) {
          final completer = owned[chapter]!;
          final result = byId[chapter.id];
          try {
            if (result?.content == null) {
              throw result?.error ?? const SourceException('书源未返回该章节正文，请重试');
            }
            // Refreshes retain the old body until both the new chapter and
            // its resources are ready. Failure must leave offline reading intact.
            if (refreshCached) await cacheImages(book, result!.content!);
            await store(book, chapter, result!.content!);
            completer.complete(result.content);
          } catch (error, stack) {
            completer.completeError(error, stack);
          }
        }
      }
    } catch (error, stack) {
      AppLog.instance.record(
        LogLevel.error,
        'download.batch_failed',
        error: error,
        stackTrace: stack,
      );
      for (final completer in owned.values) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      }
    }
    return Future.wait(waiting);
  }

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

  Future<void> saveImage(Book book, String key, Uint8List bytes) async {
    _checkCacheAvailable(book);
    await _atomic(imageFile(book, key), bytes);
  }

  Future<Uint8List> loadImage(Book book, String key) {
    if (_deletingBooks.contains(book.key)) {
      return Future.error(const SourceException('本书缓存正在删除，请稍后重试'));
    }
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

class _ShelfCheckpoints {
  _ShelfCheckpoints(this.persist, {required this.batchSize});

  final Future<void> Function() persist;
  final int batchSize;
  Completer<void>? _pending;
  Timer? _timer;
  int _waiting = 0;

  Future<void> save() {
    final pending = _pending ??= Completer<void>();
    _timer ??= Timer(const Duration(milliseconds: 250), _flush);
    if (++_waiting >= batchSize) _flush();
    return pending.future;
  }

  void _flush() {
    final pending = _pending;
    if (pending == null) return;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _waiting = 0;
    Future<void>.sync(persist).then(
      (_) => pending.complete(),
      onError: (Object error, StackTrace stack) =>
          pending.completeError(error, stack),
    );
  }
}
