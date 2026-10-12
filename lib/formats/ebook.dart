import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:enough_convert/gbk.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';
import '../domain/models.dart';

class Ebook {
  static const maxFileSize = 100 * 1024 * 1024;
  static String _hash(List<int> bytes) => sha256.convert(bytes).toString();
  static String _xml(String value) =>
      const HtmlEscape(HtmlEscapeMode.attribute).convert(
        String.fromCharCodes(
          value.runes.where(
            (r) =>
                r == 9 ||
                r == 10 ||
                r == 13 ||
                r >= 32 && r <= 0xd7ff ||
                r >= 0xe000 && r <= 0xfffd ||
                r >= 0x10000 && r <= 0x10ffff,
          ),
        ),
      );
  static String _decode(List<int> bytes) {
    if (bytes.length >= 2 &&
        (bytes[0] == 255 && bytes[1] == 254 ||
            bytes[0] == 254 && bytes[1] == 255)) {
      final little = bytes[0] == 255;
      return String.fromCharCodes([
        for (var i = 2; i + 1 < bytes.length; i += 2)
          little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
      ]);
    }
    return utf8.decode(bytes).replaceFirst(RegExp('^\uFEFF'), '');
  }

  static ImportedBook importTxt(
    Uint8List bytes,
    String fileName, {
    bool gbk = false,
  }) {
    if (bytes.length > maxFileSize) {
      throw const SourceException('文本文件不能超过 100 MB');
    }
    String text;
    if (gbk) {
      text = const GbkCodec().decode(bytes);
    } else {
      try {
        text = _decode(bytes);
      } on FormatException {
        throw const SourceException('文件不是 UTF-8/UTF-16，请选择 GBK 编码后重新导入');
      }
    }
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (text.trim().isEmpty) throw const SourceException('文本文件为空');
    final title = fileName.replaceFirst(
      RegExp(r'\.txt$', caseSensitive: false),
      '',
    );
    final chapters = <Chapter>[];
    final contents = <String, ChapterContent>{};
    final heading = RegExp(
      r'^\s*(?:第[零〇一二三四五六七八九十百千万两\d]+[章节回卷部]|序章|序言|楔子|后记|尾声|番外).{0,70}$',
      multiLine: true,
    );
    final matches = heading.allMatches(text).toList();
    void add(String name, String body) {
      if (body.trim().isEmpty) return;
      final id = '${chapters.length}';
      chapters.add(Chapter(id: id, title: name));
      contents[id] = ChapterContent(
        body
            .split('\n')
            .where((s) => s.trim().isNotEmpty)
            .map((s) => Paragraph(s.trim()))
            .toList(),
      );
    }

    if (matches.isEmpty) {
      // Large unstructured TXT files are split at line boundaries for navigation.
      var chunk = StringBuffer();
      var part = 1;
      for (final line in text.split('\n')) {
        chunk.writeln(line);
        if (chunk.length >= 15000) {
          add('正文 $part', chunk.toString());
          part++;
          chunk = StringBuffer();
        }
      }
      add('正文 $part', chunk.toString());
    } else {
      add('前言', text.substring(0, matches.first.start));
      for (var i = 0; i < matches.length; i++) {
        add(
          matches[i][0]!.trim(),
          text.substring(
            matches[i].end,
            i + 1 < matches.length ? matches[i + 1].start : text.length,
          ),
        );
      }
    }
    if (chapters.isEmpty) throw const SourceException('文本只有标题，没有正文');
    return ImportedBook(
      Book(
        id: _hash(bytes),
        title: title,
        author: '未知作者',
        source: 'local',
        chapters: chapters,
      ),
      contents,
      {},
    );
  }

  static ImportedBook importEpub(Uint8List bytes) {
    if (bytes.length > maxFileSize) {
      throw const SourceException('EPUB 文件不能超过 100 MB');
    }
    final zip = ZipDecoder().decodeBytes(bytes, verify: true);
    var total = 0;
    if (zip.length > 10000) throw const SourceException('EPUB 文件条目过多');
    for (final f in zip) {
      total += f.size;
      if (f.size > 20 * 1024 * 1024 || total > 250 * 1024 * 1024) {
        throw const SourceException('EPUB 解压后超过大小限制');
      }
      if (f.name.startsWith('/') ||
          f.name.contains('\\') ||
          f.name.split('/').contains('..')) {
        throw const SourceException('EPUB 包含不安全的资源路径');
      }
    }
    Uint8List read(String path) {
      final f = zip.findFile(path);
      if (f == null || !f.isFile) throw SourceException('EPUB 缺少资源：$path');
      return f.content;
    }

    String resolve(String base, String href) {
      final uri = Uri(path: '/$base').resolve(href);
      if (uri.hasScheme || uri.hasAuthority) {
        throw const SourceException('EPUB 的章节资源必须保存在文件内部');
      }
      return Uri.decodeComponent(uri.path.substring(1));
    }

    if (zip.findFile('META-INF/encryption.xml') != null) {
      throw const SourceException('暂不支持带 DRM 或加密资源的 EPUB');
    }
    final container = XmlDocument.parse(
      _decode(read('META-INF/container.xml')),
    );
    final root = container.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'rootfile')
        .firstOrNull;
    final opfPath = root?.getAttribute('full-path');
    if (opfPath == null) throw const SourceException('EPUB 未声明内容清单');
    final opf = XmlDocument.parse(_decode(read(opfPath)));
    String metadata(String tag, String fallback) =>
        opf.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == tag)
            .firstOrNull
            ?.innerText ??
        fallback;
    final manifest = <String, String>{};
    for (final e in opf.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'item',
    )) {
      final id = e.getAttribute('id'), href = e.getAttribute('href');
      if (id != null && href != null) manifest[id] = resolve(opfPath, href);
    }
    final chapters = <Chapter>[];
    final contents = <String, ChapterContent>{};
    final images = <String, Uint8List>{};
    for (final spine in opf.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'itemref' && e.getAttribute('linear') != 'no',
    )) {
      final path = manifest[spine.getAttribute('idref')];
      if (path == null) throw const SourceException('EPUB 阅读顺序指向未知章节');
      final doc = html.parse(_decode(read(path)));
      doc.querySelectorAll('script,style,nav').forEach((e) => e.remove());
      final title =
          doc.querySelector('h1,h2,h3')?.text.trim() ??
          doc.querySelector('title')?.text.trim() ??
          '章节 ${chapters.length + 1}';
      final heading = doc.querySelector('h1,h2,h3');
      if (heading?.text.trim() == title) heading?.remove();
      final paragraphs = <Paragraph>[];
      final text = StringBuffer();
      void flush() {
        final value = text.toString().trim();
        text.clear();
        if (value.isNotEmpty) paragraphs.add(Paragraph(value));
      }

      void visit(dom.Node node) {
        if (node is dom.Text) {
          text.write(node.text);
          return;
        }
        if (node is! dom.Element) return;
        if (node.localName == 'img') {
          flush();
          final src = node.attributes['src'];
          if (src != null) {
            final img = resolve(path, src);
            final key = 'local:${_hash(read(img))}';
            images[key] = read(img);
            paragraphs.add(Paragraph('', image: key));
          }
          return;
        }
        final block = [
          'p',
          'div',
          'h1',
          'h2',
          'h3',
          'h4',
          'li',
          'blockquote',
          'br',
          'section',
        ].contains(node.localName);
        if (block) flush();
        for (final child in node.nodes) {
          visit(child);
        }
        if (block) flush();
      }

      if (doc.body != null) visit(doc.body!);
      flush();
      if (paragraphs.isEmpty) continue;
      final cid = '${chapters.length}';
      chapters.add(Chapter(id: cid, title: title));
      contents[cid] = ChapterContent(paragraphs);
    }
    if (chapters.isEmpty) throw const SourceException('EPUB 没有可阅读的正文');
    return ImportedBook(
      Book(
        id: _hash(bytes),
        title: metadata('title', '未命名 EPUB'),
        author: metadata('creator', '未知作者'),
        source: 'local',
        chapters: chapters,
      ),
      contents,
      images,
    );
  }

  static Uint8List exportTxt(Book book, Map<String, ChapterContent> contents) {
    final out = StringBuffer('${book.title}\n作者：${book.author}\n');
    if (book.source == 'sfacg') {
      out.writeln('来源：https://book.sfacg.com/Novel/${book.id}/');
    }
    for (final chapter in book.chapters) {
      final c = contents[chapter.id];
      if (c == null) continue;
      out.writeln('\n${chapter.title}\n');
      for (final p in c.paragraphs) {
        out.writeln(
          p.image == null
              ? p.text
              : '[插图] ${p.image!.startsWith('local:') ? '(本地插图，请使用 EPUB 查看)' : p.image}',
        );
      }
    }
    return Uint8List.fromList(utf8.encode(out.toString()));
  }

  static Future<Uint8List> exportEpub(
    Book book,
    Map<String, ChapterContent> contents,
    Future<Uint8List> Function(String) loadImage,
  ) async {
    if (contents.isEmpty) throw const SourceException('没有已下载的章节');
    final zip = Archive();
    zip.addFile(
      ArchiveFile.string('mimetype', 'application/epub+zip')
        ..compression = CompressionType.none,
    );
    zip.addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
      ),
    );
    final manifest = StringBuffer(
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
    );
    final spine = StringBuffer();
    final toc = StringBuffer();
    final imagePaths = <String, String>{};
    var index = 0;
    for (final chapter in book.chapters) {
      final content = contents[chapter.id];
      if (content == null) continue;
      final body = StringBuffer('<h1>${_xml(chapter.title)}</h1>');
      for (final p in content.paragraphs) {
        if (p.image == null) {
          body.write('<p>${_xml(p.text)}</p>');
          continue;
        }
        var path = imagePaths[p.image];
        if (path == null) {
          final bytes = await loadImage(p.image!);
          final mime = bytes.length >= 4 && bytes[0] == 137 && bytes[1] == 80
              ? 'image/png'
              : bytes.length >= 3 && bytes[0] == 255 && bytes[1] == 216
              ? 'image/jpeg'
              : bytes.length >= 6 &&
                    ascii.decode(bytes.sublist(0, 3), allowInvalid: true) ==
                        'GIF'
              ? 'image/gif'
              : null;
          if (mime == null) {
            throw const SourceException('EPUB 导出暂只支持 PNG、JPEG、GIF 插图');
          }
          final ext = {
            'image/png': 'png',
            'image/jpeg': 'jpg',
            'image/gif': 'gif',
          }[mime]!;
          path = 'images/${imagePaths.length}.$ext';
          imagePaths[p.image!] = path;
          zip.addFile(ArchiveFile('OEBPS/$path', bytes.length, bytes));
          manifest.write(
            '<item id="image${imagePaths.length}" href="$path" media-type="$mime"/>',
          );
        }
        body.write('<p><img src="$path" alt="插图"/></p>');
      }
      final file = 'chapter$index.xhtml';
      zip.addFile(
        ArchiveFile.string(
          'OEBPS/$file',
          _xhtml(chapter.title, body.toString()),
        ),
      );
      manifest.write(
        '<item id="c$index" href="$file" media-type="application/xhtml+xml"/>',
      );
      spine.write('<itemref idref="c$index"/>');
      toc.write('<li><a href="$file">${_xml(chapter.title)}</a></li>');
      index++;
    }
    final title = contents.length < book.chapters.length
        ? '${book.title}（节选）'
        : book.title;
    zip.addFile(
      ArchiveFile.string(
        'OEBPS/nav.xhtml',
        _xhtml(
          title,
          '<nav xmlns:epub="http://www.idpf.org/2007/ops" epub:type="toc"><h1>目录</h1><ol>$toc</ol></nav>',
        ),
      ),
    );
    zip.addFile(
      ArchiveFile.string(
        'OEBPS/content.opf',
        '<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="bookid">urn:unr:${_xml(book.key)}</dc:identifier><dc:title>${_xml(title)}</dc:title><dc:creator>${_xml(book.author)}</dc:creator><dc:language>zh-CN</dc:language><meta property="dcterms:modified">${DateTime.now().toUtc().toIso8601String().split('.').first}Z</meta></metadata><manifest>$manifest</manifest><spine>$spine</spine></package>',
      ),
    );
    return Uint8List.fromList(ZipEncoder().encode(zip));
  }

  static String _xhtml(String title, String body) =>
      '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>${_xml(title)}</title><style>body{line-height:1.8;margin:1em;}p{text-indent:2em;}img{max-width:100%;height:auto;}</style></head><body>$body</body></html>';
}
