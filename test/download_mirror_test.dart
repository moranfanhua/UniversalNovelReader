import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/download_mirror.dart';
import 'package:unr/data/library.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

void main() {
  test('默认开启 GH-Proxy，保留完整 Raw 和 Release 下载地址', () {
    for (final original in [
      'https://raw.githubusercontent.com/google/fonts/main/NotoSansSC%5Bwght%5D.ttf',
      'https://github.com/owner/repo/releases/download/v1/font.zip',
      'https://github.com/owner/repo/releases/download/v1/font%20name.ttf?x=a%2Fb',
    ]) {
      expect(
        DownloadMirror.defaults.resolve(Uri.parse(original)).toString(),
        '${DownloadMirror.defaultBaseUrl}$original',
      );
    }
    expect(DownloadMirror.defaults.enabled, isTrue);
  });

  test('关闭后直连，自定义镜像支持路径前缀并补全末尾斜杠', () {
    final original = Uri.parse('https://github.com/owner/repo/font.ttf');
    expect(DownloadMirror(enabled: false).resolve(original), original);
    final mirror = DownloadMirror(baseUrl: ' https://mirror.example/proxy ');
    expect(mirror.baseUrl, 'https://mirror.example/proxy/');
    expect(
      mirror.resolve(original).toString(),
      'https://mirror.example/proxy/$original',
    );
  });

  test('其他域名、非 HTTPS 及带账号的地址不经过下载镜像', () {
    for (final value in [
      'https://api.example/chapters',
      'https://github.com.example/font.ttf',
      'https://api.github.com/repos/owner/repo',
      'http://raw.githubusercontent.com/owner/repo/font.ttf',
      'https://user:password@github.com/owner/repo/font.ttf',
    ]) {
      final original = Uri.parse(value);
      expect(DownloadMirror.defaults.resolve(original), original);
    }
  });

  test('无效镜像地址被拒绝', () {
    for (final value in [
      '',
      'mirror.example',
      'http://mirror.example/',
      'file:///tmp/mirror',
      'https://',
      'https://user:password@mirror.example/',
      'https://mirror.example/?token=secret',
      'https://mirror.example/#fragment',
      'https://mirror.example/a b',
      'https://mirror.example:invalid/',
    ]) {
      expect(
        () => DownloadMirror(baseUrl: value),
        throwsFormatException,
        reason: value,
      );
    }
  });

  group('下载配置持久化', () {
    late Directory root;
    late SfacgSource source;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('unr-mirror-');
      source = SfacgSource(SfacgApi());
    });
    tearDown(() async {
      source.api.close();
      await root.delete(recursive: true);
    });
    Future<Library> open() async {
      final library = await Library.open(source, directory: root);
      addTearDown(library.dispose);
      return library;
    }

    test('旧书库与损坏配置使用默认值，保留阅读进度和偏好', () async {
      for (final stored in [
        null,
        'broken',
        123,
        {'baseUrl': 'invalid'},
        {'baseUrl': 123, 'enabled': 'invalid'},
      ]) {
        await File('${root.path}/index.json').writeAsString(
          jsonEncode({
            'books': [],
            'downloadMirror': ?stored,
            'progress': {
              'local:book': [2, 5],
            },
            'fontSize': 24,
          }),
        );
        final library = await open();
        expect(library.downloadMirror.enabled, isTrue);
        expect(library.downloadMirror.baseUrl, DownloadMirror.defaultBaseUrl);
        await library.save();
        final reopened = await open();
        expect(reopened.progress['local:book'], [2, 5]);
        expect(reopened.fontSize, 24);
      }
    });

    test('自定义地址与关闭状态可恢复，重置阅读偏好保留下载配置', () async {
      final library = await open();
      await library.setDownloadMirror(
        DownloadMirror(enabled: false, baseUrl: 'https://mirror.example/proxy'),
      );
      await library.resetReadingPreferences();
      final reopened = await open();
      expect(reopened.downloadMirror.enabled, isFalse);
      expect(reopened.downloadMirror.baseUrl, 'https://mirror.example/proxy/');
      await reopened.setDownloadMirror(DownloadMirror.defaults);
      final defaults = await open();
      expect(defaults.downloadMirror.enabled, isTrue);
      expect(defaults.downloadMirror.baseUrl, DownloadMirror.defaultBaseUrl);
    });

    test('损坏地址回退默认地址但保留用户关闭状态', () async {
      await File('${root.path}/index.json').writeAsString(
        jsonEncode({
          'books': [],
          'downloadMirror': {'enabled': false, 'baseUrl': 'invalid'},
        }),
      );
      final library = await open();
      expect(library.downloadMirror.enabled, isFalse);
      expect(library.downloadMirror.baseUrl, DownloadMirror.defaultBaseUrl);
    });

    test('保存失败回滚下载配置', () async {
      final blocked = File('${root.path}/blocked');
      await blocked.writeAsString('blocked');
      final library = Library(Directory(blocked.path), source);
      addTearDown(library.dispose);
      await expectLater(
        library.setDownloadMirror(DownloadMirror(enabled: false)),
        throwsA(isA<FileSystemException>()),
      );
      expect(library.downloadMirror.enabled, isTrue);
      expect(library.downloadMirror.baseUrl, DownloadMirror.defaultBaseUrl);
    });
  });
}
