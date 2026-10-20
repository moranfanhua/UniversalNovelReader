import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:enough_convert/gbk.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';
import '../domain/models.dart';
import 'image_format.dart';

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
    final media = <String, String>{};
    String? coverPath;
    for (final e in opf.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'item',
    )) {
      final id = e.getAttribute('id'), href = e.getAttribute('href');
      if (id != null && href != null) {
        final path = resolve(opfPath, href);
        manifest[id] = path;
        media[path] = e.getAttribute('media-type') ?? '';
        if ((e.getAttribute('properties') ?? '')
            .split(RegExp(r'\s+'))
            .contains('cover-image')) {
          coverPath = path;
        }
      }
    }
    for (final meta in opf.descendants.whereType<XmlElement>()) {
      if (meta.name.local == 'meta' && meta.getAttribute('name') == 'cover') {
        coverPath ??= manifest[meta.getAttribute('content')];
      }
    }
    if (zip.findFile('META-INF/encryption.xml') != null) {
      final encryption = XmlDocument.parse(
        _decode(read('META-INF/encryption.xml')),
      );
      for (final encrypted
          in encryption.descendants.whereType<XmlElement>().where(
            (element) => element.name.local == 'EncryptedData',
          )) {
        final method = encrypted.descendants
            .whereType<XmlElement>()
            .where((element) => element.name.local == 'EncryptionMethod')
            .firstOrNull;
        final reference = encrypted.descendants
            .whereType<XmlElement>()
            .where((element) => element.name.local == 'CipherReference')
            .firstOrNull
            ?.getAttribute('URI');
        final path = reference == null ? null : resolve('', reference);
        final font = media[path];
        if (method?.getAttribute('Algorithm') !=
                'http://www.idpf.org/2008/embedding' ||
            ![
              'font/ttf',
              'font/otf',
              'application/vnd.ms-opentype',
              'application/x-font-ttf',
              'application/x-font-opentype',
            ].contains(font)) {
          throw const SourceException('暂不支持带 DRM 或加密正文资源的 EPUB');
        }
        // The reader uses its own fonts, so obfuscated fonts are never loaded.
      }
    }
    final chapters = <Chapter>[];
    final contents = <String, ChapterContent>{};
    final images = <String, Uint8List>{};
    Uint8List imageData(String base, String href) {
      final uri = Uri.tryParse(href);
      if (uri?.scheme == 'data') {
        final data = uri!.data!.contentAsBytes();
        if (data.length > 20 * 1024 * 1024) {
          throw const SourceException('EPUB 内嵌插图超过大小限制');
        }
        return Uint8List.fromList(data);
      }
      return read(resolve(base, href));
    }

    Uint8List prepareSvg(Uint8List bytes, String path) {
      final svg = XmlDocument.parse(_decode(bytes));
      svg.rootElement.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
      for (final image in svg.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'image',
      )) {
        final attribute = image.attributes
            .where((a) => a.name.local == 'href')
            .firstOrNull;
        if (attribute == null) continue;
        final data = imageData(path, attribute.value);
        final mime = ImageFormat.mime(data);
        if (mime == null || mime == 'image/svg+xml') {
          throw const SourceException('SVG 插图引用了不支持的图像资源');
        }
        attribute.value = Uri.dataFromBytes(data, mimeType: mime).toString();
      }
      return Uint8List.fromList(utf8.encode(svg.toXmlString()));
    }

    String saveImage(Uint8List bytes, String path) {
      if (ImageFormat.mime(bytes) == 'image/svg+xml') {
        bytes = prepareSvg(bytes, path);
      }
      final key = 'local:${_hash(bytes)}';
      images[key] = bytes;
      return key;
    }

    final cover = coverPath == null
        ? ''
        : saveImage(read(coverPath), coverPath);
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
        if (node.localName == 'svg') {
          flush();
          paragraphs.add(
            Paragraph(
              '',
              image: saveImage(
                Uint8List.fromList(utf8.encode(node.outerHtml)),
                path,
              ),
            ),
          );
          return;
        }
        if (node.localName == 'img') {
          flush();
          final src = node.attributes['src'];
          if (src != null) {
            final key = saveImage(
              imageData(path, src),
              src.startsWith('data:') ? path : resolve(path, src),
            );
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
        cover: cover,
        description: html.parseFragment(metadata('description', '')).text ?? '',
        chapters: chapters,
      ),
      contents,
      images,
    );
  }

  static String? _sourceUrl(Book book) => switch (book.source) {
    'sfacg' => 'https://book.sfacg.com/Novel/${book.id}/',
    'ciweimao' => 'https://www.ciweimao.com/book/${book.id}',
    _ => null,
  };

  static Uint8List exportTxt(Book book, Map<String, ChapterContent> contents) {
    final out = StringBuffer('${book.title}\n作者：${book.author}\n');
    final sourceUrl = _sourceUrl(book);
    if (sourceUrl != null) {
      out.writeln('来源：$sourceUrl');
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
    Future<String> embedImage(String key, {bool cover = false}) async {
      final existing = imagePaths[key];
      if (existing != null) return existing;
      var bytes = await loadImage(key);
      var mime = ImageFormat.mime(bytes);
      if (mime == null) {
        // Keep EPUB-compatible images intact; normalize other formats supported
        // by the reader (such as WebP and BMP) for EPUB reading systems.
        try {
          final codec = await ui.instantiateImageCodec(bytes);
          try {
            final frame = await codec.getNextFrame();
            try {
              final png = await frame.image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              if (png == null) throw StateError('PNG encoding failed');
              bytes = png.buffer.asUint8List(
                png.offsetInBytes,
                png.lengthInBytes,
              );
            } finally {
              frame.image.dispose();
            }
          } finally {
            codec.dispose();
          }
          mime = 'image/png';
        } catch (_) {
          throw SourceException(
            cover ? 'EPUB 封面无法解码或转换，请检查图片后重试' : 'EPUB 插图无法解码或转换，请检查图片后重试',
          );
        }
      }
      final path = 'images/${imagePaths.length}.${ImageFormat.extension(mime)}';
      final id = 'image${imagePaths.length}';
      imagePaths[key] = path;
      zip.addFile(ArchiveFile('OEBPS/$path', bytes.length, bytes));
      manifest.write(
        '<item id="$id" href="$path" media-type="$mime"${cover ? ' properties="cover-image"' : ''}/>',
      );
      return path;
    }

    if (book.cover.isNotEmpty) {
      final path = await embedImage(book.cover, cover: true);
      zip.addFile(
        ArchiveFile.string(
          'OEBPS/cover.xhtml',
          _xhtml(book.title, '<div><img src="$path" alt="封面"/></div>'),
        ),
      );
      manifest.write(
        '<item id="coverpage" href="cover.xhtml" media-type="application/xhtml+xml"/>',
      );
      spine.write('<itemref idref="coverpage" linear="no"/>');
    }
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
        final path = await embedImage(p.image!);
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
    if (index == 0) throw const SourceException('没有可导出的目录章节');
    final title = index < book.chapters.length
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
        '<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="bookid">urn:unr:${_xml(book.key)}</dc:identifier><dc:title>${_xml(title)}</dc:title><dc:creator>${_xml(book.author)}</dc:creator><dc:description>${_xml(book.description)}</dc:description><dc:language>zh-CN</dc:language>${_sourceUrl(book) != null ? '<dc:source>${_xml(_sourceUrl(book)!)}</dc:source>' : ''}<meta property="dcterms:modified">${DateTime.now().toUtc().toIso8601String().split('.').first}Z</meta></metadata><manifest>$manifest</manifest><spine>$spine</spine></package>',
      ),
    );
    return Uint8List.fromList(ZipEncoder().encode(zip));
  }

  static String _xhtml(String title, String body) =>
      '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>${_xml(title)}</title><style>body{line-height:1.8;margin:1em;}p{text-indent:2em;}img{max-width:100%;height:auto;}</style></head><body>$body</body></html>';
}
