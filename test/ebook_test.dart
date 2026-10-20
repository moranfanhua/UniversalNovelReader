import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:enough_convert/gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/formats/ebook.dart';
import 'package:xml/xml.dart';

final tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1QAAAAASUVORK5CYII=',
);
Uint8List fixture({
  String extraManifest = '',
  String metadata = '',
  String body = '<p>正文</p>',
  Map<String, List<int>> resources = const {},
  String? encryption,
}) {
  final zip = Archive()
    ..addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OPS/book.opf',
        '<package><metadata><title>测试</title><creator>作者</creator>$metadata</metadata><manifest><item id="chapter" href="text/chapter.xhtml" media-type="application/xhtml+xml"/>$extraManifest</manifest><spine><itemref idref="chapter"/></spine></package>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OPS/text/chapter.xhtml',
        '<html><head><title>章节</title></head><body>$body</body></html>',
      ),
    );
  if (encryption != null) {
    zip.addFile(ArchiveFile.string('META-INF/encryption.xml', encryption));
  }
  for (final resource in resources.entries) {
    zip.addFile(
      ArchiveFile(resource.key, resource.value.length, resource.value),
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(zip));
}

class ObservedContent extends ChapterContent {
  ObservedContent(this.events, this.text) : super(const []);
  final SendPort events;
  final String text;
  @override
  List<Paragraph> get paragraphs {
    events.send(Isolate.current.debugName);
    return [Paragraph(text), const Paragraph('', image: 'shared')];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('大书逐章请求并在后台生成和压缩，封面插图去重且文件可重新导入', () async {
    final directory = await Directory.systemTemp.createTemp('unr-export-test-');
    addTearDown(() => directory.delete(recursive: true));
    final events = ReceivePort();
    addTearDown(events.close);
    final encoded = <String?>[];
    final observed = Completer<void>();
    events.listen((event) {
      encoded.add(event as String?);
      if (encoded.length == 80) observed.complete();
    });
    final chapters = [
      for (var i = 0; i < 80; i++) Chapter(id: '$i', title: '章节$i'),
    ];
    final book = Book(
      id: 'large',
      title: '大书',
      author: '作者',
      cover: 'shared',
      chapters: chapters,
    );
    final reads = <String>[];
    var active = 0, imageReads = 0, ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => ticks++,
    );
    addTearDown(timer.cancel);
    final file = await Ebook.exportEpubFile(
      book,
      (chapter) async {
        expect(++active, 1);
        reads.add(chapter.id);
        await Future<void>.delayed(Duration.zero);
        active--;
        return ObservedContent(
          events.sendPort,
          '${chapter.id}正文${'长文本' * 7000}',
        );
      },
      (_) async {
        imageReads++;
        return tinyPng;
      },
      temporaryDirectory: directory,
    );
    await observed.future;
    expect(encoded.toSet(), {'epub.export'});
    expect(reads, chapters.map((chapter) => chapter.id));
    expect(imageReads, 1);
    expect(ticks, greaterThan(0));
    final bytes = await file.readAsBytes();
    final zip = ZipDecoder().decodeBytes(bytes, verify: true);
    expect(zip.first.name, 'mimetype');
    expect(zip.first.compression, CompressionType.none);
    final imported = Ebook.importEpub(bytes);
    expect(
      imported.book.chapters.map((chapter) => chapter.title),
      chapters.map((chapter) => chapter.title),
    );
    expect(imported.images, hasLength(1));
    expect(imported.contents['79']!.paragraphs.first.text, startsWith('79正文'));
    await file.parent.delete(recursive: true);
    expect(await directory.list().toList(), isEmpty);
  });

  test('资源失败和取消均关闭后台文件并清理临时目录，不继续读取后续章节', () async {
    final directory = await Directory.systemTemp.createTemp(
      'unr-export-failure-',
    );
    addTearDown(() => directory.delete(recursive: true));
    const book = Book(
      id: 'failure',
      title: '',
      author: '',
      chapters: [
        Chapter(id: '1', title: ''),
        Chapter(id: '2', title: ''),
      ],
    );
    for (final cancel in [true, false]) {
      var cancelled = false, reads = 0;
      await expectLater(
        Ebook.exportEpubFile(
          book,
          (chapter) async {
            reads++;
            cancelled = cancel;
            return const ChapterContent([Paragraph('', image: 'missing')]);
          },
          (_) async => throw const SourceException('插图获取失败'),
          isCancelled: () => cancelled,
          temporaryDirectory: directory,
        ),
        throwsA(isA<SourceException>()),
      );
      expect(reads, 1);
      expect(await directory.list().toList(), isEmpty);
    }
  });

  Future<(int, int, Uint8List)> pixels(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        final data = (await frame.image.toByteData())!;
        return (
          frame.image.width,
          frame.image.height,
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  // Locally generated 2 x 3 solid-color images; WebP includes transparency.
  final otherImages = {
    'WebP': base64Decode(
      'UklGRh4AAABXRUJQVlA4TBEAAAAvAYAAEAfQll50qICBiOh/AAA=',
    ),
    'BMP': base64Decode(
      'Qk1OAAAAAAAAADYAAAAoAAAAAgAAAAMAAAABABgAAAAAABgAAADEDgAAxA4AAAAAAAAAAAAAQy0XQy0XAABDLRdDLRcAAEMtF0MtFwAA',
    ),
  };
  for (final entry in otherImages.entries) {
    test('${entry.key} 封面与插图转为 PNG，保留尺寸像素并复用资源', () async {
      const key = 'https://example.com/cover.jpg';
      const book = Book(
        id: 'converted',
        title: '图片转换',
        author: '作者',
        cover: key,
        chapters: [Chapter(id: '1', title: '第一章')],
      );
      var loads = 0;
      final original = Uint8List.fromList(entry.value);
      final bytes = await Ebook.exportEpub(
        book,
        {
          '1': const ChapterContent([
            Paragraph('前文'),
            Paragraph('', image: key),
            Paragraph('后文'),
          ]),
        },
        (_) async {
          loads++;
          return entry.value;
        },
      );
      expect(loads, 1);
      expect(entry.value, original);
      final zip = ZipDecoder().decodeBytes(bytes, verify: true);
      final opf = XmlDocument.parse(
        utf8.decode(zip.findFile('OEBPS/content.opf')!.content),
      );
      final image = opf.descendants.whereType<XmlElement>().singleWhere(
        (e) => e.getAttribute('properties') == 'cover-image',
      );
      expect(image.getAttribute('media-type'), 'image/png');
      expect(image.getAttribute('href'), 'images/0.png');
      final imported = Ebook.importEpub(bytes);
      expect(imported.images.length, 1);
      final converted = imported.images[imported.book.cover]!;
      expect(converted.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final before = await pixels(original), after = await pixels(converted);
      expect((after.$1, after.$2), (2, 3));
      expect(after.$3, before.$3);
      final paragraphs = imported.contents['0']!.paragraphs;
      expect(paragraphs.map((p) => p.text), ['前文', '', '后文']);
      expect(paragraphs[1].image, imported.book.cover);
    });
  }

  for (final cover in [true, false]) {
    test('无法解码的${cover ? '封面' : '插图'}仍阻止导出并明确提示', () async {
      const key = 'https://example.com/private-image';
      final book = Book(
        id: 'invalid-image',
        title: '测试',
        author: '',
        cover: cover ? key : '',
        chapters: const [Chapter(id: '1', title: '第一章')],
      );
      await expectLater(
        Ebook.exportEpub(book, {
          '1': ChapterContent([
            const Paragraph('正文'),
            if (!cover) const Paragraph('', image: key),
          ]),
        }, (_) async => Uint8List.fromList(utf8.encode('<html>加载失败</html>'))),
        throwsA(
          isA<SourceException>().having(
            (e) => e.toString(),
            'message',
            contains(cover ? 'EPUB 封面无法解码或转换' : 'EPUB 插图无法解码或转换'),
          ),
        ),
      );
    });
  }

  test('EPUB 2 与 3 声明的封面都导入本地资源', () {
    for (final version in [2, 3]) {
      final imported = Ebook.importEpub(
        fixture(
          extraManifest:
              '<item id="cover" href="images/封面%20图.png" media-type="image/png" ${version == 3 ? 'properties="cover-image"' : ''}/>',
          metadata: version == 2 ? '<meta name="cover" content="cover"/>' : '',
          resources: {'OPS/images/封面 图.png': tinyPng},
        ),
      );
      expect(imported.images[imported.book.cover], tinyPng);
      expect(imported.book.chapters.length, 1);
    }
  });
  test('字体混淆不妨碍正文导入，正文加密仍给出明确错误', () {
    String encryption(String path, String algorithm) =>
        '<encryption><EncryptedData><EncryptionMethod Algorithm="$algorithm"/><CipherData><CipherReference URI="$path"/></CipherData></EncryptedData></encryption>';
    const algorithm = 'http://www.idpf.org/2008/embedding';
    final input = fixture(
      extraManifest:
          '<item id="font" href="fonts/body.ttf" media-type="font/ttf"/>',
      encryption: encryption('OPS/fonts/body.ttf', algorithm),
      resources: {
        'OPS/fonts/body.ttf': [1, 2, 3],
      },
    );
    expect(Ebook.importEpub(input).contents['0']!.paragraphs.single.text, '正文');
    for (final method in [
      algorithm,
      'http://www.w3.org/2001/04/xmlenc#aes128-cbc',
    ]) {
      expect(
        () => Ebook.importEpub(
          fixture(encryption: encryption('OPS/text/chapter.xhtml', method)),
        ),
        throwsA(isA<SourceException>()),
      );
    }
  });
  test('SVG 插图中的相对图片转换成内嵌资源，保持前后文字', () {
    final imported = Ebook.importEpub(
      fixture(
        body:
            '<p>前文</p><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 100"><image xlink:href="../images/a.png" width="100" height="100"/></svg><p>后文</p>',
        resources: {'OPS/images/a.png': tinyPng},
      ),
    );
    expect(imported.contents['0']!.paragraphs.map((p) => p.text), [
      '前文',
      '',
      '后文',
    ]);
    final svg = utf8.decode(imported.images.values.single);
    expect(svg, contains('data:image/png;base64,'));
    expect(svg, isNot(contains('../images/a.png')));
  });
  test('data URI 插图导入，SVG 封面与简介可导出后再次导入', () async {
    final svg = utf8.encode(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 60"><rect width="40" height="60" fill="green"/></svg>',
    );
    final imported = Ebook.importEpub(
      fixture(
        body:
            '<p>文字</p><img src="${Uri.dataFromBytes(tinyPng, mimeType: 'image/png')}"/>',
        extraManifest:
            '<item id="cover" href="cover.svg" media-type="image/svg+xml" properties="cover-image"/>',
        metadata: '<description>简介 &amp; 中文</description>',
        resources: {'OPS/cover.svg': svg},
      ),
    );
    final output = await Ebook.exportEpub(
      imported.book,
      imported.contents,
      (key) async => imported.images[key]!,
    );
    final roundtrip = Ebook.importEpub(output);
    expect(roundtrip.book.cover, isNotEmpty);
    expect(roundtrip.book.description, '简介 & 中文');
    expect(roundtrip.book.chapters.length, 1);
    expect(
      roundtrip.images.values.any(
        (bytes) => utf8.decode(bytes, allowMalformed: true).contains('<svg'),
      ),
      isTrue,
    );
    expect(roundtrip.contents['0']!.paragraphs.first.text, '文字');
  });
  test('中文 EPUB 往返保留顺序、XML 字符、表情和插图', () async {
    const book = Book(
      id: 'test',
      title: '原创 & <😀>',
      author: '测试作者',
      source: 'local',
      chapters: [
        Chapter(id: 'b', title: '第一章 &'),
        Chapter(id: 'a', title: '第二章'),
      ],
    );
    final contents = {
      'a': const ChapterContent([Paragraph('第二章正文')]),
      'b': const ChapterContent([
        Paragraph('甲 & < > 😀'),
        Paragraph('', image: 'local:image'),
        Paragraph('后文'),
      ]),
    };
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1QAAAAASUVORK5CYII=',
    );
    final output = await Ebook.exportEpub(
      book,
      contents,
      (_) => Future.value(png),
    );
    // EPUB requires the first ZIP entry to be an uncompressed mimetype.
    final header = ByteData.sublistView(output);
    expect(header.getUint16(8, Endian.little), 0);
    expect(utf8.decode(output.sublist(30, 38)), 'mimetype');
    final zip = ZipDecoder().decodeBytes(output, verify: true);
    expect(
      utf8.decode(zip.findFile('mimetype')!.content),
      'application/epub+zip',
    );
    final imported = Ebook.importEpub(output);
    expect(imported.book.title, book.title);
    expect(imported.book.author, book.author);
    expect(imported.book.chapters.map((c) => c.title), ['第一章 &', '第二章']);
    expect(imported.contents['0']!.paragraphs.first.text, '甲 & < > 😀');
    expect(imported.contents['0']!.paragraphs.last.text, '后文');
    expect(imported.images.values.single, png);
  });
  test('TXT 按章拆分，支持 UTF-8 和显式 GBK', () {
    final text = '前言正文\n第一章 开始\n甲\n第二章 结束\n乙';
    final a = Ebook.importTxt(Uint8List.fromList(utf8.encode(text)), '测试.txt');
    final b = Ebook.importTxt(
      Uint8List.fromList(const GbkCodec().encode(text)),
      '测试.txt',
      gbk: true,
    );
    expect(a.book.chapters.map((c) => c.title), ['前言', '第一章 开始', '第二章 结束']);
    expect(b.contents['2']!.paragraphs.single.text, '乙');
    expect(
      utf8.decode(Ebook.exportTxt(a.book, a.contents)),
      contains('第二章 结束\n\n乙'),
    );
  });
  test('缺失章节明确标记 EPUB 节选', () async {
    const book = Book(
      id: 'id',
      title: '测试小说',
      author: '作者',
      chapters: [
        Chapter(id: '1', title: '一'),
        Chapter(id: '2', title: '二'),
      ],
    );
    final bytes = await Ebook.exportEpub(book, {
      '2': const ChapterContent([Paragraph('保留正文')]),
    }, (_) => throw StateError('没有图片'));
    final imported = Ebook.importEpub(bytes);
    expect(imported.book.title, '测试小说（节选）');
    expect(imported.book.chapters.single.title, '二');
  });
  test('EPUB 导入拒绝目录穿越条目', () {
    final zip = Archive()..addFile(ArchiveFile.string('../evil', 'bad'));
    expect(
      () => Ebook.importEpub(Uint8List.fromList(ZipEncoder().encode(zip))),
      throwsA(isA<SourceException>()),
    );
  });
  test('EPUB 插图下载失败不生成缺图的成功文件', () async {
    const book = Book(
      id: 'id',
      title: '测试',
      author: '',
      chapters: [Chapter(id: '1', title: '一')],
    );
    expect(
      Ebook.exportEpub(book, {
        '1': const ChapterContent([
          Paragraph('', image: 'https://rss.sfacg.com/missing.jpg'),
        ]),
      }, (_) => Future.error(const SourceException('插图失败'))),
      throwsA(isA<SourceException>()),
    );
  });
}
