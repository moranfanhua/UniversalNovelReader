import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/data/reader_fonts.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg_api.dart';
import 'package:unr/sources/sfacg_source.dart';

Uint8List engineTestFont() {
  var directory = File(Platform.resolvedExecutable).parent;
  while (directory.parent.path != directory.path) {
    final file = File(
      '${directory.path}/packages/flutter_tools/static/Ahem.ttf',
    );
    if (file.existsSync()) return file.readAsBytesSync();
    directory = directory.parent;
  }
  throw StateError('找不到 Flutter 自带的 Ahem 测试字体');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('unr-fonts-test-'),
  );
  tearDown(() async => root.delete(recursive: true));
  const id = 'noto-sans-sc';
  const license = 'Copyright test fixture\nSIL OPEN FONT LICENSE Version 1.1';
  test('字体及许可下载后加载到 Flutter，离线重新打开可恢复阅读偏好', () async {
    final bytes = engineTestFont();
    final requests = <Uri>[];
    final progress = <int>[];
    final fonts = ReaderFonts(
      Directory('${root.path}/fonts'),
      clientFactory: () => MockClient((request) async {
        requests.add(request.url);
        expect(request.headers.containsKey('Cookie'), isFalse);
        expect(request.headers.containsKey('Authorization'), isFalse);
        return request.url.path.endsWith('.ttf')
            ? http.Response.bytes(bytes, 200)
            : http.Response(license, 200);
      }),
    );
    final api = SfacgApi();
    final library = Library(root, SfacgSource(api), fonts: fonts);
    library.horizontalMargin = 38;
    library.verticalMargin = 32;
    library.lineHeight = 2.2;
    await library.downloadFont(
      id,
      onProgress: (received, total) => progress.add(received),
    );
    expect(requests.length, 2);
    expect(progress.last, bytes.length);
    expect(library.readingFontFamily, startsWith('UNR_noto-sans-sc_'));
    expect(library.downloadedFonts, contains(id));
    expect(await fonts.licenseText(id), license);
    final offlineFonts = ReaderFonts(
      Directory('${root.path}/fonts'),
      clientFactory: () => throw StateError('不应联网'),
    );
    final reopened = await Library.open(
      library.source,
      directory: root,
      fonts: offlineFonts,
    );
    expect(reopened.readingFontId, id);
    expect(reopened.readingFontFamily, library.readingFontFamily);
    expect(
      [reopened.horizontalMargin, reopened.verticalMargin, reopened.lineHeight],
      [38, 32, 2.2],
    );
    expect(await offlineFonts.download(id), library.readingFontFamily);
    reopened.dispose();
    library.dispose();
    api.close();
  });
  test('HTTP 错误或伪装成字体的 HTML 不保存字体、不改变所选字体', () async {
    final api = SfacgApi();
    for (final response in [
      http.Response('missing', 404),
      http.Response.bytes(utf8.encode('<html>错误页</html>'), 200),
    ]) {
      final fonts = ReaderFonts(
        Directory('${root.path}/fonts'),
        clientFactory: () => MockClient((_) async => response),
      );
      final library = Library(root, SfacgSource(api), fonts: fonts)
        ..readingFontFamily = 'current';
      await expectLater(
        library.downloadFont(id),
        throwsA(isA<SourceException>()),
      );
      expect(library.readingFontFamily, 'current');
      expect(library.readingFontId, '');
      expect(await fonts.available(), isEmpty);
      library.dispose();
    }
    api.close();
  });
  test('取消字体下载不留下半个字体文件，后续可重新下载', () async {
    final bytes = engineTestFont();
    final fonts = ReaderFonts(
      Directory('${root.path}/fonts'),
      clientFactory: () => MockClient.streaming((request, body) async {
        return request.url.path.endsWith('.ttf')
            ? http.StreamedResponse(
                Stream.fromIterable([bytes.sublist(0, 64), bytes.sublist(64)]),
                200,
                contentLength: bytes.length,
              )
            : http.StreamedResponse(Stream.value(utf8.encode(license)), 200);
      }),
    );
    await expectLater(
      fonts.download(
        id,
        onProgress: (received, total) {
          if (received > 0) fonts.cancel();
        },
      ),
      throwsA(
        isA<SourceException>().having((e) => e.message, '取消原因', contains('取消')),
      ),
    );
    expect(await fonts.available(), isEmpty);
    expect(
      (await root.list(recursive: true).toList()).where(
        (file) => file.path.endsWith('.tmp'),
      ),
      isEmpty,
    );
    expect(await fonts.download(id), startsWith('UNR_'));
  });
  test('过大的下载声明与截断字体被拒绝', () async {
    final fonts = ReaderFonts(
      Directory('${root.path}/fonts'),
      clientFactory: () => MockClient.streaming(
        (_, body) async => http.StreamedResponse(
          const Stream.empty(),
          200,
          contentLength: ReaderFonts.maxSize + 1,
        ),
      ),
    );
    await expectLater(fonts.download(id), throwsA(isA<SourceException>()));
    expect(
      () => ReaderFonts.validate(
        Uint8List.fromList([0, 1, 0, 0, ...List.filled(12, 0)]),
      ),
      throwsA(isA<SourceException>()),
    );
  });
  test('损坏的已选字体在启动时回退系统字体，书库仍能打开', () async {
    final fontsRoot = Directory('${root.path}/fonts');
    await fontsRoot.create();
    await File('${fontsRoot.path}/$id.ttf').writeAsString('broken');
    await File('${fontsRoot.path}/$id.ofl').writeAsString(license);
    await File(
      '${root.path}/index.json',
    ).writeAsString(jsonEncode({'books': [], 'readingFontId': id}));
    final api = SfacgApi();
    final library = await Library.open(SfacgSource(api), directory: root);
    expect(library.readingFontFamily, isNull);
    expect(library.fontNotice, isNotNull);
    expect(library.downloadedFonts, isNot(contains(id)));
    library.dispose();
    api.close();
  });
}
