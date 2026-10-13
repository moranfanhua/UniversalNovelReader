import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/formats/ebook.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('unr-cache-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  const chapter = Chapter(
    id: '1',
    title: '第一章',
    url: 'https://book.sfacg.com/Novel/1/2/1/',
  );
  const book = Book(id: '1', title: '测试书', author: '测试', chapters: [chapter]);

  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1QAAAAASUVORK5CYII=',
  );
  const illustratedBook = Book(
    id: '1',
    title: '测试书',
    author: '测试',
    chapters: [chapter],
    cover: 'https://rs.sfacg.com/cover.png',
  );
  const illustration = 'https://rs.sfacg.com/illustration.png';

  test('下载包含封面和插图，断网重开后可阅读并导出 EPUB 和 TXT', () async {
    final calls = <String, int>{};
    final api = SfacgApi(
      client: MockClient((request) async {
        final url = request.url.toString();
        calls[url] = (calls[url] ?? 0) + 1;
        if (url == chapter.url) {
          return http.Response(
            '<div id="ChapterBody"><p>离线正文</p><p><img src="$illustration"></p></div>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }
        expect([illustratedBook.cover, illustration], contains(url));
        return http.Response.bytes(png, 200);
      }),
    );
    final library = Library(root, SfacgSource(api));
    await library.add(illustratedBook);
    final content = await library.read(illustratedBook, chapter);
    await library.cacheImages(illustratedBook, content);
    await library.cacheImages(illustratedBook, content);
    expect(calls, {chapter.url: 1, illustration: 1, illustratedBook.cover: 1});
    api.close();

    var offlineRequests = 0;
    final offlineApi = SfacgApi(
      client: MockClient((_) async {
        offlineRequests++;
        throw const SocketException('离线');
      }),
    );
    addTearDown(offlineApi.close);
    final reopened = await Library.open(
      SfacgSource(offlineApi),
      directory: root,
    );
    final savedBook = reopened.books.single;
    final savedContent = await reopened.read(
      savedBook,
      savedBook.chapters.single,
    );
    expect(savedContent.paragraphs.first.text, '离线正文');
    final contents = await reopened.cachedContents(savedBook);
    final epub = await Ebook.exportEpub(
      savedBook,
      contents,
      (key) => reopened.loadImage(savedBook, key),
    );
    final imported = Ebook.importEpub(epub);
    expect(imported.images[imported.book.cover], png);
    final paragraphs = imported.contents.values.expand((c) => c.paragraphs);
    expect(paragraphs.map((p) => p.text), contains('离线正文'));
    final image = paragraphs.firstWhere((p) => p.image != null).image!;
    expect(imported.images[image], png);
    expect(utf8.decode(Ebook.exportTxt(savedBook, contents)), contains('离线正文'));
    expect(offlineRequests, 0);
  });

  test('封面下载失败明确报错，保留已缓存正文和插图，重试只补封面', () async {
    var coverCalls = 0, imageCalls = 0;
    final api = SfacgApi(
      client: MockClient((request) async {
        if (request.url.toString() == illustratedBook.cover) {
          coverCalls++;
          if (coverCalls == 1) return http.Response('', 503);
        } else {
          expect(request.url.toString(), illustration);
          imageCalls++;
        }
        return http.Response.bytes(png, 200);
      }),
    );
    addTearDown(api.close);
    final library = Library(root, SfacgSource(api));
    const content = ChapterContent([
      Paragraph('缓存正文'),
      Paragraph('', image: illustration),
    ]);
    await library.store(illustratedBook, chapter, content);
    await expectLater(
      library.cacheImages(illustratedBook, content),
      throwsA(isA<SourceException>()),
    );
    expect(await library.image(illustratedBook, illustratedBook.cover), isNull);
    expect(await library.image(illustratedBook, illustration), png);
    expect(
      (await library.cached(illustratedBook, chapter))!.paragraphs.first.text,
      '缓存正文',
    );
    await library.cacheImages(illustratedBook, content);
    expect(coverCalls, 2);
    expect(imageCalls, 1);
    expect(await library.image(illustratedBook, illustratedBook.cover), png);
  });

  test('同时读取同一章节只请求一次，后续可离线读取', () async {
    var calls = 0;
    final response = Completer<http.Response>();
    final api = SfacgApi(
      client: MockClient((_) {
        calls++;
        return response.future;
      }),
    );
    final library = Library(root, SfacgSource(api));
    final first = library.read(book, chapter),
        second = library.read(book, chapter);
    response.complete(
      http.Response(
        '<div id="ChapterBody"><p>缓存正文</p></div>',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      ),
    );
    final result = await Future.wait([first, second]);
    expect(calls, 1);
    expect(result[0], same(result[1]));
    api.close();
    expect((await library.read(book, chapter)).paragraphs.single.text, '缓存正文');
  });

  test('失败请求释放占位，重试不会永久返回第一次失败', () async {
    var calls = 0;
    final api = SfacgApi(
      client: MockClient((_) async {
        calls++;
        return http.Response(
          calls == 1 ? '' : '<div id="ChapterBody"><p>成功正文</p></div>',
          calls == 1 ? 503 : 200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }),
    );
    final library = Library(root, SfacgSource(api));
    await expectLater(
      library.read(book, chapter),
      throwsA(isA<SourceException>()),
    );
    expect((await library.read(book, chapter)).paragraphs.single.text, '成功正文');
    expect(calls, 2);
    api.close();
  });

  test('并发缓存写入不会争抢同一个临时文件或留下半个 JSON', () async {
    final api = SfacgApi();
    final library = Library(root, SfacgSource(api));
    await Future.wait([
      library.store(book, chapter, const ChapterContent([Paragraph('甲')])),
      library.store(book, chapter, const ChapterContent([Paragraph('乙')])),
    ]);
    expect([
      '甲',
      '乙',
    ], contains((await library.cached(book, chapter))!.paragraphs.single.text));
    expect(
      (await root.list(recursive: true).toList()).where(
        (e) => e.path.endsWith('.tmp'),
      ),
      isEmpty,
    );
    final index = File('${root.path}/index.json');
    await library.add(book);
    await library.remember(book, 0, 3);
    expect(
      (jsonDecode(await index.readAsString()) as Map)['progress'][book.key],
      [0, 3],
    );
    api.close();
  });
}
