import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:enough_convert/gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/formats/ebook.dart';

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

void main() {
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
