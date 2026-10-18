import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../domain/models.dart';
import 'download_mirror.dart';

class CloudFont {
  const CloudFont(
    this.id,
    this.name,
    this._downloadUrl,
    this._licenseUrl, {
    this.source = 'Google Fonts',
    this.archivePath,
    this.notice,
  });
  final String id, name, source, _downloadUrl, _licenseUrl;
  final String? archivePath, notice;
  Uri get download => Uri.parse(_downloadUrl);
  Uri get license => Uri.parse(_licenseUrl);
}

const _rawGithub = 'https://raw.githubusercontent.com';
const _github = 'https://github.com';

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
      '$_rawGithub/google/fonts/main/ofl/notosanssc/NotoSansSC[wght].ttf',
      '$_rawGithub/google/fonts/main/ofl/notosanssc/OFL.txt',
    ),
    CloudFont(
      'noto-serif-sc',
      'Noto Serif SC · 宋体',
      '$_rawGithub/google/fonts/main/ofl/notoserifsc/NotoSerifSC[wght].ttf',
      '$_rawGithub/google/fonts/main/ofl/notoserifsc/OFL.txt',
    ),
    CloudFont(
      'lxgw-wenkai-gb-screen',
      '霞鹜文楷 GB 屏幕版 · 楷体',
      '$_github/lxgw/LxgwWenKai-Screen/releases/download/v1.522/LXGWWenKaiGBScreen.ttf',
      '$_rawGithub/lxgw/LxgwWenKai-Screen/v1.522/OFL.txt',
      source: '落霞孤鹜',
    ),
    CloudFont(
      'chill-round-m',
      '寒蝉半圆体 · 圆体',
      '$_github/Warren2060/ChillRound/releases/download/v1.805/ChillRoundM_v1.805.zip',
      '$_rawGithub/Warren2060/ChillRound/v1.805/LICENSE',
      source: '寒蝉字型',
      archivePath: 'ChillRoundM_v1.805/ChillRoundM.ttf',
    ),
    CloudFont(
      'yozai',
      '悠哉字体 · 手写体',
      '$_github/lxgw/yozai-font/releases/download/v0.868/Yozai-Regular.ttf',
      '$_rawGithub/lxgw/yozai-font/v0.868/OFL.txt',
      source: '落霞孤鹜',
    ),
    CloudFont(
      'zhuque-fangsong',
      '朱雀仿宋 · 仿宋体',
      '$_github/TrionesType/zhuque/releases/download/v0.212/ZhuqueFangsong-v0.212.zip',
      '$_rawGithub/TrionesType/zhuque/v0.212/LICENSE.txt',
      source: '璇玑造字',
      archivePath: 'ZhuqueFangsong-Regular.ttf',
      notice: '朱雀仿宋目前为上游预览测试版，部分字形和排版效果仍在完善。',
    ),
    CloudFont(
      'ibm-plex-sans-sc',
      'IBM Plex Sans SC · 黑体',
      '$_rawGithub/IBM/plex/71f558992315a12ca1f06a2215d57962a1992162/'
          'packages/plex-sans-sc/fonts/complete/otf/hinted/IBMPlexSansSC-Regular.otf',
      '$_rawGithub/IBM/plex/71f558992315a12ca1f06a2215d57962a1992162/'
          'packages/plex-sans-sc/LICENSE.txt',
      source: 'IBM',
    ),
    CloudFont(
      'lxgw-zhenkai-gb',
      '霞鹜臻楷 GB · 楷体',
      '$_github/lxgw/LxgwZhenKai/releases/download/v0.827/LXGWZhenKaiSlabGB-Regular.ttf',
      '$_rawGithub/lxgw/LxgwZhenKai/v0.827/OFL.txt',
      source: '落霞孤鹜',
    ),
    CloudFont(
      'xiaolai',
      '小赖字体 · 手写体',
      '$_github/lxgw/kose-font/releases/download/v3.126/Xiaolai-Regular.ttf',
      '$_rawGithub/lxgw/kose-font/v3.126/OFL.txt',
      source: '落霞孤鹜',
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

  static Uint8List _unpack(CloudFont font, Uint8List bytes) {
    final path = font.archivePath;
    if (path == null) return bytes;
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final file = archive.findFile(path);
      if (file == null || !file.isFile || file.isSymbolicLink) {
        throw const SourceException('字体压缩包缺少所需字体');
      }
      if (file.size < 12 || file.size > maxSize) {
        throw const SourceException('字体文件大小无效');
      }
      final content = file.content;
      if (content.length != file.size || getCrc32(content) != file.crc32) {
        throw const SourceException('字体压缩包损坏，请重试');
      }
      return content;
    } on SourceException {
      rethrow;
    } catch (_) {
      throw const SourceException('字体压缩包损坏，请重试');
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
    DownloadMirror mirror = DownloadMirror.defaults,
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
      final bytes = _unpack(
        option,
        await _fetch(
          client,
          mirror.resolve(option.download),
          maxSize,
          onProgress,
        ),
      );
      validate(bytes);
      final license = await _fetch(
        client,
        mirror.resolve(option.license),
        128 * 1024,
        null,
      );
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
