import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../data/library.dart';
import '../domain/models.dart';
import '../formats/ebook.dart';
import 'account.dart';
import 'book_page.dart';
import 'image_bytes.dart';
import 'settings.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.library});
  final Library library;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  bool busy = false, gbk = false;
  String? error;
  final query = TextEditingController();
  List<Book>? results;
  Library get library => widget.library;
  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> _open(String input) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final book = await library.source.getBook(input);
      await library.add(book);
      await library.markActive(book);
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BookPage(library: library, book: book),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _search() async {
    final text = query.text.trim();
    if (text.isEmpty) return;
    if (RegExp(r'^\d+$').hasMatch(text) || text.startsWith('http')) {
      await _open(text);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await library.source.search(text);
      if (mounted) setState(() => results = data);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
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
        setState(() => tab = 0);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已导入《${imported.book.title}》')));
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _openShelfBook(Book book) async {
    try {
      await library.markActive(book);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => BookPage(library: library, book: book),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) =>
      _buildPage(context, library.sortedBooks);

  Widget _buildPage(BuildContext context, List<Book> shelf) => Scaffold(
    appBar: AppBar(
      title: Text(['我的书库', '菠萝包轻小说', '账号', '设置'][tab]),
      actions: [
        IconButton(
          tooltip: '开源许可',
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'UNR 阅读器',
            applicationVersion: '0.1.1',
            applicationLegalese: 'AGPL-3.0\n非官方阅读器，作品与段评归相应权利人所有。',
          ),
          icon: const Icon(Icons.info_outline),
        ),
        if (tab == 0)
          IconButton(
            tooltip: '导入 EPUB / TXT',
            onPressed: busy ? null : _import,
            icon: const Icon(Icons.add),
          ),
      ],
    ),
    body: Column(
      children: [
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
                              '把故事放进你的书库',
                              style: Theme.of(context).textTheme.headlineSmall,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              '导入一本 EPUB / TXT，或从菠萝包开始阅读。',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 28),
                            FilledButton.icon(
                              onPressed: busy ? null : _import,
                              icon: const Icon(Icons.file_open_outlined),
                              label: const Text('导入小说'),
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: () => setState(() => tab = 1),
                              child: const Text('添加菠萝包作品'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(20),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 230,
                            mainAxisSpacing: 20,
                            crossAxisSpacing: 18,
                            childAspectRatio: .64,
                          ),
                      itemCount: shelf.length,
                      itemBuilder: (context, i) {
                        final book = shelf[i];
                        return InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _openShelfBook(book),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: BookCover(book: book, library: library),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                book.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                book.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              Text(
                                book.source == 'sfacg'
                                    ? '菠萝包 · ${book.chapters.length} 章'
                                    : '本地 · ${book.chapters.length} 章',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: TextField(
                          controller: query,
                          onSubmitted: busy ? null : (_) => _search(),
                          decoration: InputDecoration(
                            hintText: '作品 ID、作品链接或书名',
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
                      if (results == null)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('输入菠萝包书名搜索，也可以直接添加作品 ID 或链接。'),
                        ),
                      if (results?.isEmpty == true)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('没有搜索到作品'),
                        ),
                      Expanded(
                        child: ListView(
                          children: [
                            for (final book in results ?? <Book>[])
                              ListTile(
                                leading: SizedBox(
                                  width: 46,
                                  height: 64,
                                  child: BookCover(book: book),
                                ),
                                title: Text(book.title),
                                subtitle: Text(book.author),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: busy ? null : () => _open(book.id),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              AccountPage(library: library),
              SettingsPage(
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
          label: '账号',
        ),
        NavigationDestination(icon: Icon(Icons.tune), label: '设置'),
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
  Widget _placeholder(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    color: Theme.of(context).colorScheme.primaryContainer,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.menu_book, size: 40),
        const SizedBox(height: 16),
        Text(
          book.title,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    ),
  );
}
