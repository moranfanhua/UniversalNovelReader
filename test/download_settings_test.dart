import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/download_mirror.dart';
import 'package:unr/data/library.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/download_settings.dart';
import 'package:unr/ui/settings.dart';

class DownloadSettingsLibrary extends Library {
  DownloadSettingsLibrary()
    : super(Directory.systemTemp, SfacgSource(SfacgApi()));

  Completer<void>? pendingSave;
  @override
  Future<void> save() async {
    notifyListeners();
    await pendingSave?.future;
  }
}

void main() {
  for (final width in [360.0, 1200.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('下载设置可进入、校验、保存、关闭和恢复（宽$width，缩放$scale）', (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final library = DownloadSettingsLibrary();
        addTearDown(library.dispose);
        addTearDown(library.source.api.close);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: SoftwareSettingsPage(
              library: library,
              gbk: false,
              onEncodingChanged: (_) {},
            ),
          ),
        );
        final entry = find.byKey(const ValueKey('settings-download-entry'));
        await tester.scrollUntilVisible(entry, 180);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(find.text('下载设置'), findsOneWidget);
        final toggle = find.byKey(const ValueKey('download-mirror-enabled'));
        final address = find.byKey(const ValueKey('download-mirror-address'));
        final save = find.byKey(const ValueKey('download-mirror-save'));
        Future<void> tap(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
        await tester.enterText(address, 'invalid');
        await tap(save);
        expect(find.textContaining('请输入有效的 HTTPS 镜像地址'), findsOneWidget);
        expect(library.downloadMirror.baseUrl, DownloadMirror.defaultBaseUrl);
        await tester.enterText(address, 'https://mirror.example/proxy');
        await tap(save);
        expect(library.downloadMirror.baseUrl, 'https://mirror.example/proxy/');
        expect(find.text('已保存，将用于下次下载。'), findsOneWidget);
        await tap(toggle);
        expect(library.downloadMirror.enabled, isFalse);
        await tap(find.text('恢复默认下载设置'));
        expect(library.downloadMirror.enabled, isTrue);
        expect(library.downloadMirror.baseUrl, DownloadMirror.defaultBaseUrl);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('保存期间禁用重复操作，失败后显示原因并可重试', (tester) async {
    final library = DownloadSettingsLibrary();
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DownloadSettings(library: library)),
      ),
    );
    final toggle = find.byKey(const ValueKey('download-mirror-enabled'));
    library.pendingSave = Completer<void>();
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
    expect(find.text('正在保存…'), findsOneWidget);
    library.pendingSave!.completeError(const FileSystemException('无法写入'));
    await tester.pumpAndSettle();
    expect(library.downloadMirror.enabled, isTrue);
    expect(find.textContaining('下载设置保存失败'), findsOneWidget);
    library.pendingSave = null;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(library.downloadMirror.enabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存中离开页面不访问已销毁的输入框', (tester) async {
    final library = DownloadSettingsLibrary();
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DownloadSettings(library: library)),
      ),
    );
    library.pendingSave = Completer<void>();
    await tester.enterText(find.byType(TextField), 'https://mirror.example/');
    await tester.tap(find.text('保存地址'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    library.pendingSave!.complete();
    await tester.pumpAndSettle();
    expect(library.downloadMirror.baseUrl, 'https://mirror.example/');
    expect(tester.takeException(), isNull);
  });
}
