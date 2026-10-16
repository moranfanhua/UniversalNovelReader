import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../data/library.dart';
import '../data/app_log.dart';
import '../domain/models.dart';
import '../formats/ebook.dart';
import '../sources/novel_search.dart';
import 'book_page.dart';
import 'reader.dart';
import 'image_bytes.dart';
import 'my.dart';
import 'import_shelf.dart';
import '../domain/bookshelf.dart';

enum _ShelfBookAction { details, pin, remove }

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.library});
  final Library library;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  bool busy = false, gbk = false, searchFailed = false;
  String? error;
  final query = TextEditingController();
  List<Book>? results;
  List<String> searchNotices = [];
  String? selectedShelf;
  Library get library => widget.library;
  late List<String> searchSourceIds;
  int searchGeneration = 0;

  @override
  void initState() {
    super.initState();
    searchSourceIds = library.enabledSearchSources
        .map((source) => source.id)
        .toList();
    library.addListener(_searchSourcesChanged);
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != library) {
      oldWidget.library.removeListener(_searchSourcesChanged);
      library.addListener(_searchSourcesChanged);
      _searchSourcesChanged();
    }
  }

  void _searchSourcesChanged() {
    final ids = library.enabledSearchSources
        .map((source) => source.id)
        .toList();
    if (listEquals(searchSourceIds, ids)) return;
    setState(() {
      searchSourceIds = ids;
      searchGeneration++;
      results = null;
      searchNotices = [];
      searchFailed = false;
      error = null;
    });
  }

  @override
  void dispose() {
    library.removeListener(_searchSourcesChanged);
    query.dispose();
    super.dispose();
  }

  Future<void> _open(String input, {String? sourceId}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final link = RegExp(r'https?://[^\s<>「」“”]+').firstMatch(input);
      final host = link == null
          ? null
          : Uri.tryParse(link[0]!)?.host.toLowerCase();
      final sourceHint =
          sourceId ??
          ({
                'qidian.com',
                'www.qidian.com',
                'm.qidian.com',
                'book.qidian.com',
              }.contains(host)
              ? 'qidian'
              : [
                      'fanqienovel.com',
                      'www.fanqienovel.com',
                      'reading.snssdk.com',
                    ].contains(host) ||
                    RegExp(r'^[1-9]\d{14,19}$').hasMatch(input.trim())
              ? 'fanqie'
              : 'sfacg');
      final service = library.searchSources.firstWhere(
        (source) => source.id == sourceHint,
        orElse: () => throw const SourceException('对应书源尚未启用'),
      );
      final book = await service.getBook(input);
      await library.updateBook(book);
      await library.markActive(book);
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BookPage(library: library, book: book),
          ),
        );
      }
    } catch (e, stack) {
      AppLog.instance.record(
        LogLevel.error,
        'book.open_failed',
        error: e,
        stackTrace: stack,
      );
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _search() async {
    if (busy) return;
    final text = query.text.trim();
    if (text.isEmpty) return;
    if (RegExp(r'^\d+$').hasMatch(text) ||
        text.contains(RegExp(r'https?://'))) {
      await _open(text);
      return;
    }
    final sources = library.enabledSearchSources;
    if (sources.isEmpty) {
      setState(() {
        results = null;
        searchNotices = [];
        searchFailed = false;
        error = '未选择搜索平台，请在软件设置的“搜索”中开启至少一个平台。';
      });
      return;
    }
    final generation = ++searchGeneration;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await searchNovels(sources, text);
      if (mounted && generation == searchGeneration) {
        setState(() {
          results = data.books;
          searchNotices = data.notices;
          searchFailed =
              data.failedSources.isNotEmpty &&
              data.failedSources.length == sources.length;
          if (data.failedSources.isNotEmpty) {
            error =
                '${data.failedSources.join('、')}搜索失败，请重试。${data.failedSources.length < sources.length ? '已显示其他平台的结果。' : ''}';
          }
        });
      }
    } catch (e, stack) {
      AppLog.instance.record(
        LogLevel.error,
        'search.failed',
        error: e,
        stackTrace: stack,
      );
      if (mounted && generation == searchGeneration) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _import() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['epub', 'txt'],
        dialogTitle: '导入 EPUB 或 TXT',
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final name = file.name;
      final imported = await compute(_parseImport, (
        bytes: bytes,
        name: name,
        gbk: gbk,
      ));
      await library.import(imported);
      if (mounted) {
        setState(() {
          tab = 0;
          selectedShelf = null;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已导入《${imported.book.title}》')));
      }
    } catch (e, stack) {
      AppLog.instance.record(
        LogLevel.error,
        'import.failed',
        error: e,
        stackTrace: stack,
      );
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _chooseImport() async {
    final method = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.apps),
              title: const Text('从软件导入'),
              onTap: () => Navigator.pop(context, 'software'),
            ),
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('从本地导入'),
              subtitle: const Text('EPUB / TXT'),
              onTap: () => Navigator.pop(context, 'local'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (method == 'local') {
      await _import();
    } else if (method == 'software') {
      final shelf = await Navigator.push<Bookshelf>(
        context,
        MaterialPageRoute(builder: (_) => ImportShelfPage(library: library)),
      );
      if (mounted && shelf != null) {
        setState(() => selectedShelf = shelf.id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已导入书架“${shelf.name}”，共 ${shelf.bookKeys.length} 本作品',
            ),
          ),
        );
      }
    }
  }

  Future<void> _openShelfBook(Book book, {bool details = false}) async {
    if (busy) return;
    final service = library.sourceFor(book);
    if (!details && book.chapters.isEmpty && service == null) {
      setState(() => error = '当前作品暂无可阅读章节，可长按作品查看详情。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final openingTab = tab, openingShelf = selectedShelf;
    bool active() =>
        mounted &&
        tab == openingTab &&
        selectedShelf == openingShelf &&
        (ModalRoute.of(context)?.isCurrent ?? false);
    try {
      if (book.chapters.isEmpty && service != null) {
        final full = await service.getBook(book.id);
        if (!active()) return;
        if (full.key != book.key || full.chapters.isEmpty) {
          throw const SourceException('书源未返回对应作品的完整目录，请重试');
        }
        await library.updateBook(full);
        book = full;
      }
      if (!active()) return;
      await library.markActive(book);
      if (!mounted || !active()) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => details
              ? BookPage(library: library, book: book)
              : ReaderPage(library: library, book: book),
        ),
      );
    } catch (e) {
      if (active()) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _toggleShelfLayout() async {
    try {
      await library.setShelfLayout(
        library.shelfLayout == ShelfLayout.grid
            ? ShelfLayout.list
            : ShelfLayout.grid,
      );
    } catch (e) {
      if (mounted) setState(() => error = '显示方式保存失败：$e');
    }
  }

  Future<void> _shelfBookActions(Book book) async {
    if (busy) return;
    final shelfId = selectedShelf;
    final pinned = library.isBookPinned(book);
    final action = await showModalBottomSheet<_ShelfBookAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('作品详情'),
              onTap: () => Navigator.pop(context, _ShelfBookAction.details),
            ),
            ListTile(
              leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(pinned ? '取消置顶' : '置顶'),
              onTap: () => Navigator.pop(context, _ShelfBookAction.pin),
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('移除'),
              onTap: () => Navigator.pop(context, _ShelfBookAction.remove),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == _ShelfBookAction.details) {
      await _openShelfBook(book, details: true);
      return;
    }
    setState(() => busy = true);
    try {
      if (action == _ShelfBookAction.pin) {
        await library.setBookPinned(book, !library.isBookPinned(book));
      } else {
        await library.removeFromShelf(book, shelfId: shelfId);
      }
    } catch (e) {
      if (mounted) setState(() => error = '书架操作失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _shelfCover(Book book) => Stack(
    fit: StackFit.expand,
    children: [
      BookCover(book: book, library: library),
      if (library.isBookPinned(book))
        Positioned(
          top: 6,
          right: 6,
          child: Tooltip(
            message: '已置顶',
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.push_pin,
                  size: 16,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        ),
    ],
  );

  Widget _shelfGrid(List<Book> shelf) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 600;
      final spacing = compact ? 12.0 : 18.0;
      final desiredWidth = compact ? 100.0 : 150.0;
      final available = math.max(1.0, constraints.maxWidth - 40);
      final columns = math.min(
        shelf.length,
        compact
            ? 3
            : math.max(
                1,
                ((available + spacing) / (desiredWidth + spacing)).floor(),
              ),
      );
      final width = math.min(
        desiredWidth,
        (available - (columns - 1) * spacing) / columns,
      );
      final scale = width / 150;
      final titleSize = 13.0 * scale, detailSize = 11.5 * scale;
      final textScaler = MediaQuery.textScalerOf(context);
      final height =
          width * 1.5 +
          14 * scale +
          (textScaler.scale(titleSize) * 1.3).ceilToDouble() * 2 +
          (textScaler.scale(detailSize) * 1.4).ceilToDouble() * 2 +
          4;
      return Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: columns * width + (columns - 1) * spacing + 40,
          child: GridView.builder(
            key: const PageStorageKey('shelf-grid'),
            padding: const EdgeInsets.all(20),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 20,
              crossAxisSpacing: spacing,
              mainAxisExtent: height,
            ),
            itemCount: shelf.length,
            itemBuilder: (context, i) {
              final book = shelf[i];
              return InkWell(
                key: ValueKey('shelf-book-${book.key}'),
                borderRadius: BorderRadius.circular(14),
                onTap: () => _openShelfBook(book),
                onLongPress: () => _shelfBookActions(book),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: width * 1.5, child: _shelfCover(book)),
                    SizedBox(height: 10 * scale),
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: titleSize,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 4 * scale),
                    Text(
                      book.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: detailSize,
                        height: 1.4,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      '${library.sourceName(book)} · ${book.chapters.isEmpty && library.sourceFor(book) != null ? '目录待加载' : '${book.chapters.length} 章'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: detailSize,
                        height: 1.4,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    },
  );

  String _readingStatus(Book book) {
    final saved = library.progress[book.key];
    if (saved == null || saved.isEmpty) return '未读过';
    if (book.chapters.isEmpty) return _emptyDirectoryLabel(book);
    final index = saved.first.clamp(0, book.chapters.length - 1);
    final remaining = book.chapters.length - index - 1;
    return '已读至第 ${index + 1} 章${remaining > 0 ? ' · $remaining 章未读' : ''}';
  }

  String _updateSummary(Book book) {
    if (book.source == 'local') return '本地小说 · 共 ${book.chapters.length} 章';
    final updated = book.updatedAt;
    var label = '更新时间未知';
    if (updated != null) {
      final age = library.clock().difference(updated);
      if (age.isNegative || age.inDays >= 30) {
        final date = updated.toLocal();
        label =
            '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}更新';
      } else if (age.inDays > 0) {
        label = '${age.inDays}天前更新';
      } else if (age.inHours > 0) {
        label = '${age.inHours}小时前更新';
      } else if (age.inMinutes > 0) {
        label = '${age.inMinutes}分钟前更新';
      } else {
        label = '刚刚更新';
      }
    }
    if (book.chapters.isEmpty) return '$label · ${_emptyDirectoryLabel(book)}';
    final latest = book.chapters.last;
    return '$label · 第${book.chapters.length}章 ${latest.title}${latest.wordCount == null ? '' : '（${latest.wordCount}字）'}';
  }

  String _emptyDirectoryLabel(Book book) =>
      library.sourceFor(book) == null ? '暂无章节目录' : '目录待加载';

  Widget _shelfList(List<Book> shelf) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: ListView.separated(
        key: const PageStorageKey('shelf-list'),
        padding: const EdgeInsets.all(20),
        itemCount: shelf.length,
        separatorBuilder: (_, _) => const SizedBox(height: 20),
        itemBuilder: (context, i) {
          final book = shelf[i];
          final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
          return InkWell(
            key: ValueKey('shelf-book-${book.key}'),
            borderRadius: BorderRadius.circular(14),
            onTap: () => _openShelfBook(book),
            onLongPress: () => _shelfBookActions(book),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 64, height: 96, child: _shelfCover(book)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _readingStatus(book),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: secondary),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _updateSummary(book),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: secondary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: library,
    builder: (context, _) => _buildLibrary(context),
  );

  Widget _buildLibrary(BuildContext context) {
    if (selectedShelf == Library.recentShelfId) {
      return _buildPage(context, library.sortedRecentBooks);
    }
    final keys = library.shelves
        .where((s) => s.id == selectedShelf)
        .firstOrNull
        ?.bookKeys
        .toSet();
    return _buildPage(
      context,
      library.sortedBooks
          .where((b) => keys == null || keys.contains(b.key))
          .toList(),
    );
  }

  Widget _buildPage(BuildContext context, List<Book> shelf) => Scaffold(
    appBar: AppBar(
      toolbarHeight: 48,
      titleTextStyle: Theme.of(context).textTheme.titleMedium,
      title: Text(['我的书库', '搜索', '我的'][tab]),
      actions: [
        IconButton(
          tooltip: '开源许可',
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'UNR 阅读器',
            applicationVersion: const String.fromEnvironment(
              'APP_VERSION',
              defaultValue: '开发版',
            ),
            applicationLegalese: 'AGPL-3.0\n非官方阅读器，作品与段评归相应权利人所有。',
          ),
          icon: const Icon(Icons.info_outline),
        ),
        if (tab == 0)
          IconButton(
            tooltip: '导入',
            onPressed: busy ? null : _chooseImport,
            icon: const Icon(Icons.add),
          ),
      ],
    ),
    body: Column(
      children: [
        if (tab == 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    key: const ValueKey('bookshelf-selector'),
                    isExpanded: true,
                    value: selectedShelf ?? '',
                    items: [
                      const DropdownMenuItem(value: '', child: Text('全部作品')),
                      const DropdownMenuItem(
                        value: Library.recentShelfId,
                        child: Text('最近阅读'),
                      ),
                      for (final shelf in library.shelves)
                        DropdownMenuItem(
                          value: shelf.id,
                          child: Text(
                            '${shelf.name}（${shelf.bookKeys.length}）',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (id) =>
                        setState(() => selectedShelf = id == '' ? null : id),
                  ),
                ),
                IconButton(
                  key: const ValueKey('shelf-layout-toggle'),
                  tooltip: library.shelfLayout == ShelfLayout.grid
                      ? '切换为列表'
                      : '切换为宫格',
                  onPressed: busy ? null : _toggleShelfLayout,
                  icon: Icon(
                    library.shelfLayout == ShelfLayout.grid
                        ? Icons.view_list_outlined
                        : Icons.grid_view,
                  ),
                ),
              ],
            ),
          ),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          MaterialBanner(
            content: Text(error!),
            actions: [
              TextButton(
                onPressed: () => setState(() => error = null),
                child: const Text('关闭'),
              ),
            ],
          ),
        Expanded(
          child: IndexedStack(
            index: tab,
            children: [
              shelf.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.auto_stories_outlined,
                              size: 72,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(height: 24),
                            Text(
                              selectedShelf == null
                                  ? '把故事放进你的书库'
                                  : selectedShelf == Library.recentShelfId
                                  ? '还没有最近阅读记录'
                                  : '这个书架暂无作品',
                              style: Theme.of(context).textTheme.headlineSmall,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              '从软件导入书架、导入 EPUB / TXT，或从书源开始阅读。',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 28),
                            FilledButton.icon(
                              onPressed: busy ? null : _chooseImport,
                              icon: const Icon(Icons.file_open_outlined),
                              label: const Text('导入小说'),
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: () => setState(() => tab = 1),
                              child: const Text('添加网络作品'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : library.shelfLayout == ShelfLayout.grid
                  ? _shelfGrid(shelf)
                  : _shelfList(shelf),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: TextField(
                          controller: query,
                          enabled: !busy,
                          onSubmitted: busy ? null : (_) => _search(),
                          decoration: InputDecoration(
                            hintText: '搜索书名或作者，也可粘贴作品 ID、链接',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: IconButton(
                              tooltip: '搜索或添加作品',
                              onPressed: busy ? null : _search,
                              icon: const Icon(Icons.arrow_forward),
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                        ),
                      ),
                      for (final notice in searchNotices)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                          child: Text(
                            notice,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      if (results?.isEmpty == true)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(searchFailed ? '搜索未完成，请重试' : '没有搜索到作品'),
                        ),
                      Expanded(
                        child: ListView(
                          children: [
                            for (final book in results ?? <Book>[])
                              ListTile(
                                key: ValueKey('search-${book.key}'),
                                leading: SizedBox(
                                  width: 46,
                                  height: 64,
                                  child: BookCover(book: book),
                                ),
                                title: Text(book.title),
                                subtitle: Text(
                                  '${book.author} · ${library.sourceName(book)}\n${book.favoriteCount == null ? '收藏数未知' : '${book.favoriteCount} 人收藏'}',
                                ),
                                isThreeLine: true,
                                trailing: const Icon(Icons.chevron_right),
                                onTap: busy
                                    ? null
                                    : () =>
                                          _open(book.id, sourceId: book.source),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              MyPage(
                library: library,
                gbk: gbk,
                onEncodingChanged: (value) => setState(() => gbk = value),
              ),
            ],
          ),
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (v) => setState(() => tab = v),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.library_books_outlined),
          selectedIcon: Icon(Icons.library_books),
          label: '书库',
        ),
        NavigationDestination(icon: Icon(Icons.travel_explore), label: '书源'),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: '我的',
        ),
      ],
    ),
  );
}

ImportedBook _parseImport(({Uint8List bytes, String name, bool gbk}) data) =>
    data.name.toLowerCase().endsWith('.epub')
    ? Ebook.importEpub(data.bytes)
    : Ebook.importTxt(data.bytes, data.name, gbk: data.gbk);

class BookCover extends StatefulWidget {
  const BookCover({super.key, required this.book, this.library});
  final Book book;
  final Library? library;
  @override
  State<BookCover> createState() => _BookCoverState();
}

class _BookCoverState extends State<BookCover> {
  Future<Uint8List>? bytes;
  Book get book => widget.book;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    bytes = book.cover.isEmpty
        ? null
        : widget.library?.loadImage(book, book.cover);
  }

  @override
  void didUpdateWidget(BookCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book.key != book.key ||
        oldWidget.book.cover != book.cover ||
        oldWidget.library != widget.library) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: AspectRatio(
      aspectRatio: 2 / 3,
      child: bytes != null
          ? FutureBuilder<Uint8List>(
              future: bytes,
              builder: (context, snapshot) => snapshot.hasData
                  ? ImageBytes(
                      snapshot.data!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, error, stack) => _placeholder(context),
                    )
                  : _placeholder(context),
            )
          : book.cover.isNotEmpty && !book.cover.startsWith('local:')
          ? Image.network(
              book.cover,
              fit: BoxFit.cover,
              errorBuilder: (_, error, stack) => _placeholder(context),
            )
          : _placeholder(context),
    ),
  );
  Widget _placeholder(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.primaryContainer,
    child: LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight < 140 || constraints.maxWidth < 80) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Icon(Icons.menu_book, size: 28),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.menu_book, size: 40),
              const SizedBox(height: 16),
              Flexible(
                child: Text(
                  book.title,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
