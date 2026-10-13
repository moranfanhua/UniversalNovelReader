import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../domain/models.dart';

class CloudFont {
  const CloudFont(this.id, this.name, this.folder, this.filename);
  final String id, name, folder, filename;
  Uri get download => Uri.https(
    'raw.githubusercontent.com',
    '/google/fonts/main/ofl/$folder/$filename',
  );
  Uri get license => Uri.https(
    'raw.githubusercontent.com',
    '/google/fonts/main/ofl/$folder/OFL.txt',
  );
}

class ReaderFonts {
  ReaderFonts(
    this.root, {
    http.Client Function()? clientFactory,
    Future<void> Function(String, Uint8List)? register,
  }) : clientFactory = clientFactory ?? http.Client.new,
       register = register ?? _register;
  static const catalog = [
    CloudFont(
      'noto-sans-sc',
      'Noto Sans SC · 黑体',
      'notosanssc',
      'NotoSansSC[wght].ttf',
    ),
    CloudFont(
      'noto-serif-sc',
      'Noto Serif SC · 宋体',
      'notoserifsc',
      'NotoSerifSC[wght].ttf',
    ),
  ];
  static const maxSize = 64 * 1024 * 1024;
  final Directory root;
  final http.Client Function() clientFactory;
  final Future<void> Function(String, Uint8List) register;
  final _loaded = <String>{};
  http.Client? _client;
  bool _cancelled = false;
  bool _busy = false;
  static CloudFont font(String id) => catalog.firstWhere(
    (f) => f.id == id,
    orElse: () => throw const SourceException('未知阅读字体'),
  );
  File _file(String id) => File('${root.path}/${font(id).id}.ttf');
  File _license(String id) => File('${root.path}/${font(id).id}.ofl');

  static Future<void> _register(String family, Uint8List bytes) async {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }

  static void validate(Uint8List bytes) {
    if (bytes.length < 12 || bytes.length > maxSize) {
      throw const SourceException('字体文件大小无效');
    }
    final data = ByteData.sublistView(bytes);
    if (![0x00010000, 0x4f54544f].contains(data.getUint32(0))) {
      throw const SourceException('下载内容不是 TTF / OTF 字体');
    }
    final count = data.getUint16(4);
    if (count == 0 || count > 256 || 12 + count * 16 > bytes.length) {
      throw const SourceException('字体文件不完整');
    }
    final tables = <String>{};
    for (var i = 0; i < count; i++) {
      final pos = 12 + i * 16;
      final offset = data.getUint32(pos + 8), size = data.getUint32(pos + 12);
      if (offset < 12 + count * 16 || offset + size > bytes.length) {
        throw const SourceException('字体资源表不完整');
      }
      tables.add(ascii.decode(bytes.sublist(pos, pos + 4), allowInvalid: true));
    }
    if (!tables.containsAll(['cmap', 'head', 'hhea', 'hmtx', 'maxp', 'name'])) {
      throw const SourceException('字体缺少必要资源表');
    }
  }

  Future<Set<String>> available() async {
    final found = <String>{};
    for (final option in catalog) {
      if (await _file(option.id).exists() &&
          await _license(option.id).exists()) {
        found.add(option.id);
      }
    }
    return found;
  }

  Future<String> _loadBytes(String id, Uint8List bytes) async {
    validate(bytes);
    final family =
        'UNR_${id}_${sha256.convert(bytes).toString().substring(0, 12)}';
    if (!_loaded.contains(family)) {
      await register(family, bytes);
      _loaded.add(family);
    }
    return family;
  }

  Future<String> load(String id) async {
    if (!await _file(id).exists() || !await _license(id).exists()) {
      throw const SourceException('阅读字体未下载，请先下载字体');
    }
    return _loadBytes(id, await _file(id).readAsBytes());
  }

  Future<String> licenseText(String id) => _license(id).readAsString();
  void cancel() {
    _cancelled = true;
    _client?.close();
  }

  Future<Uint8List> _fetch(
    http.Client client,
    Uri uri,
    int limit,
    void Function(int received, int? total)? progress,
  ) async {
    final response = await client
        .send(http.Request('GET', uri))
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw SourceException('字体下载失败（HTTP ${response.statusCode}）');
    }
    final total = response.contentLength;
    if (total != null && total > limit) {
      throw const SourceException('字体文件超过大小限制');
    }
    final builder = BytesBuilder();
    progress?.call(0, total);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 25),
    )) {
      if (_cancelled) throw const SourceException('字体下载已取消');
      builder.add(chunk);
      if (builder.length > limit) throw const SourceException('字体文件超过大小限制');
      progress?.call(builder.length, total);
    }
    if (total != null && builder.length != total) {
      throw const SourceException('字体下载不完整，请重试');
    }
    return builder.takeBytes();
  }

  Future<void> _write(File file, Uint8List bytes) async {
    await root.create(recursive: true);
    final temp = File('${file.path}.${const Uuid().v4()}.tmp');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<String> download(
    String id, {
    void Function(int, int?)? onProgress,
  }) async {
    final option = font(id);
    if (_busy) throw const SourceException('已有字体正在下载');
    _busy = true;
    _cancelled = false;
    http.Client? client;
    try {
      try {
        final family = await load(id);
        if (_cancelled) throw const SourceException('字体下载已取消');
        return family;
      } catch (_) {
        if (_cancelled) rethrow;
        // Missing or damaged cache can be downloaded again.
      }
      client = _client = clientFactory();
      final bytes = await _fetch(client, option.download, maxSize, onProgress);
      validate(bytes);
      final license = await _fetch(client, option.license, 128 * 1024, null);
      if (!utf8.decode(license).contains('SIL OPEN FONT LICENSE')) {
        throw const SourceException('无法取得字体开源许可');
      }
      if (_cancelled) throw const SourceException('字体下载已取消');
      final family = await _loadBytes(id, bytes);
      if (_cancelled) throw const SourceException('字体下载已取消');
      await _write(_license(id), license);
      await _write(_file(id), bytes);
      if (_cancelled) throw const SourceException('字体下载已取消');
      return family;
    } catch (e) {
      if (_cancelled) throw const SourceException('字体下载已取消');
      rethrow;
    } finally {
      client?.close();
      _client = null;
      _busy = false;
    }
  }
}
