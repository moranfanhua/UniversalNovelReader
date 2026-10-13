import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/data/session.dart';
import 'package:unr/formats/ebook.dart';
import 'package:unr/sources/sfacg_source.dart';
import 'package:unr/ui/account.dart';

class UnavailableStorage extends FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw PlatformException(code: 'storage_unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  const key = 'unr.sfacg.session.v1';
  test('安全存储不可读时继续启动，提示恢复失败且不覆盖旧会话', () async {
    FlutterSecureStorage.setMockInitialValues({key: '保留旧数据'});
    final api = await SfacgSession.open(storage: UnavailableStorage());
    addTearDown(api.close);
    expect(api.hasSession, isFalse);
    expect(api.sessionNotice, contains('无法恢复'));
    expect(await const FlutterSecureStorage().read(key: key), '保留旧数据');
  });

  test('损坏账号缓存不会阻止启动，重新保存有效会话后提示消失', () async {
    for (final value in [
      '{broken',
      '[]',
      '{"device": 12}',
      '{"nonce": false}',
      '{"cookie": 12}',
      '{"cookie": ".SFCommunity=incomplete"}',
    ]) {
      FlutterSecureStorage.setMockInitialValues({key: value});
      final api = await SfacgSession.open();
      expect(api.hasSession, isFalse);
      expect(api.sessionNotice, contains('无法恢复'));
      expect(await const FlutterSecureStorage().read(key: key), value);
      api.setCookie('.SFCommunity=synthetic; session_APP=synthetic-session');
      await api.onSessionChanged!();
      expect(api.sessionNotice, isNull);
      final restored = await SfacgSession.open();
      expect(restored.hasSession, isTrue);
      expect(restored.sessionNotice, isNull);
      restored.close();
      api.close();
    }
  });

  test('账号恢复失败后仍能重开并读取已导入 TXT 正文', () async {
    final root = await Directory.systemTemp.createTemp('unr-session-test-');
    addTearDown(() => root.delete(recursive: true));
    final initialApi = await SfacgSession.open();
    addTearDown(initialApi.close);
    final initial = Library(root, SfacgSource(initialApi));
    final data = Ebook.importTxt(
      Uint8List.fromList(utf8.encode('第一章 开始\n账号损坏后仍可见的正文')),
      '本地书.txt',
    );
    await initial.import(data);
    FlutterSecureStorage.setMockInitialValues({key: '{broken'});
    final api = await SfacgSession.open();
    addTearDown(api.close);
    final library = await Library.open(SfacgSource(api), directory: root);
    final book = library.books.single;
    final content = await library.read(book, book.chapters.single);
    expect(content.paragraphs.map((p) => p.text), contains('账号损坏后仍可见的正文'));
    expect(await const FlutterSecureStorage().read(key: key), '{broken');
  });

  testWidgets('账号页显示恢复失败提示', (tester) async {
    FlutterSecureStorage.setMockInitialValues({key: '{broken'});
    final api = await SfacgSession.open();
    addTearDown(api.close);
    final library = Library(Directory.systemTemp, SfacgSource(api));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AccountPage(library: library)),
      ),
    );
    expect(find.textContaining('无法恢复本机菠萝包会话'), findsOneWidget);
    await tester.tap(find.text('登录菠萝包'));
    await tester.pumpAndSettle();
    expect(find.text('请填写账号和密码'), findsOneWidget);
    expect(await const FlutterSecureStorage().read(key: key), '{broken');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('安全存储恢复设备标识、nonce 和两个 App Cookie', () async {
    final api = await SfacgSession.open();
    api.setCookie(
      '.SFCommunity=synthetic-community; session_APP=synthetic-session',
    );
    final nonce = api.nonce, device = api.device;
    await api.onSessionChanged!();
    final saved = jsonDecode(
      (await const FlutterSecureStorage().read(key: 'unr.sfacg.session.v1'))!,
    );
    expect(saved['nonce'], nonce);
    final restored = await SfacgSession.open();
    expect(restored.nonce, nonce);
    expect(restored.device, device);
    expect(restored.cookies, api.cookies);
    await SfacgSession.logout(restored);
    expect((await SfacgSession.open()).hasSession, isFalse);
    api.close();
    restored.close();
  });
}
