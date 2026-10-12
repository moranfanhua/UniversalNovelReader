import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:enough_convert/gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/formats/ebook.dart';

void main() {
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
