import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:unr/data/app_update.dart';
import 'package:unr/data/download_mirror.dart';
import 'package:unr/data/library.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/about.dart';
import 'helpers/app_release.dart';

class AboutMemoryLibrary extends Library {
  AboutMemoryLibrary() : super(Directory.systemTemp, SfacgSource(SfacgApi()));
  @override
  Future<void> save() async {}
}

void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });
  late AboutMemoryLibrary library;

  void mockVersion({String version = '0.3.2'}) {
    PackageInfo.setMockInitialValues(
      appName: 'UNR 阅读器',
      packageName: 'io.github.moranfanhua.unr',
      version: version,
      buildNumber: '4',
      buildSignature: '',
    );
  }

  setUp(() {
    mockVersion();
    library = AboutMemoryLibrary();
  });
  tearDown(() {
    library.dispose();
    library.source.api.close();
  });

  Future<void> showPage(
    WidgetTester tester, {
    Future<http.Response> Function(http.Request)? respond,
    Future<bool> Function(Uri)? openUrl,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.android
        ? const Size(320, 640)
        : const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: AboutPage(
          library: library,
          updates: AppUpdates(
            clientFactory: () => MockClient((request) {
              expect(request.url, AppUpdates.latestRelease);
              return respond?.call(request) ??
                  Future.value(jsonResponse(releaseJson()));
            }),
          ),
          openUrl: openUrl,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('显示已安装版本和构建号，许可仍可进入', (tester) async {
    await showPage(tester);
    expect(find.text('0.3.2+4'), findsOneWidget);
    await tester.tap(find.text('开源许可'));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('0.3.2+4'), findsOneWidget);
    expect(find.textContaining('AGPL-3.0'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('检查更新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('当前已是最新版本，失败后可以重新检查', (tester) async {
    var calls = 0;
    await showPage(
      tester,
      respond: (_) async => ++calls == 1
          ? http.Response('', 500)
          : jsonResponse(releaseJson(version: '0.3.2')),
    );
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP 500'), findsOneWidget);
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('当前已是最新正式版本'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('版本读取失败可重试，不发送无版本的检查', (tester) async {
    mockVersion(version: '');
    var calls = 0;
    await showPage(
      tester,
      respond: (_) async {
        calls++;
        return jsonResponse(releaseJson());
      },
    );
    expect(find.text('版本读取失败，点击重试'), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('about-check-update')))
          .onTap,
      isNull,
    );
    expect(calls, 0);
    mockVersion();
    await tester.tap(find.text('当前版本'));
    await tester.pumpAndSettle();
    expect(find.text('0.3.2+4'), findsOneWidget);
  });

  for (final mirror in [
    DownloadMirror.defaults,
    DownloadMirror(baseUrl: 'https://mirror.example/proxy/'),
    DownloadMirror(enabled: false),
  ]) {
    testWidgets('检查直连，下载遵循镜像设置 ${mirror.baseUrl} ${mirror.enabled}', (
      tester,
    ) async {
      await library.setDownloadMirror(mirror);
      final opened = <Uri>[];
      await showPage(
        tester,
        openUrl: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 0.4.0'), findsNWidgets(2));
      expect(find.text('更新说明：修复阅读问题'), findsOneWidget);
      expect(opened, isEmpty);
      await tester.tap(find.text('下载更新'));
      await tester.pumpAndSettle();
      final suffix = defaultTargetPlatform == TargetPlatform.windows
          ? 'windows-x64.zip'
          : 'android-universal.apk';
      final original = Uri.parse(
        'https://github.com/moranfanhua/UniversalNovelReader/releases/download/v0.4.0/unr-0.4.0-$suffix',
      );
      expect(opened, [mirror.resolve(original)]);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: platforms);
  }

  testWidgets('稍后取消不会下载，缺失安装包时不显示下载按钮', (tester) async {
    var opened = false;
    await showPage(tester, openUrl: (_) async => opened = true);
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(opened, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await showPage(
      tester,
      respond: (_) async => jsonResponse({...releaseJson(), 'assets': []}),
    );
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂未提供'), findsOneWidget);
    expect(find.text('下载更新'), findsNothing);
  });

  testWidgets('打开下载失败留在弹窗并可重试，重复点击不会重复打开', (tester) async {
    var calls = 0;
    final opening = Completer<bool>();
    await showPage(
      tester,
      openUrl: (_) async {
        calls++;
        if (calls == 1) return false;
        return opening.future;
      },
    );
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    expect(find.text('无法打开下载链接，请重试'), findsOneWidget);
    await tester.tap(find.text('下载更新'));
    await tester.pump();
    await tester.tap(find.text('正在打开…'));
    expect(calls, 2);
    opening.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('正在检查时禁用按钮，页面关闭后丢弃返回结果', (tester) async {
    final response = Completer<http.Response>();
    var calls = 0;
    await showPage(
      tester,
      respond: (_) {
        calls++;
        return response.future;
      },
    );
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await tester.tap(find.text('正在检查更新…'));
    expect(calls, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    response.complete(jsonResponse(releaseJson()));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机与宽屏、大字体、长更新说明均可操作', (tester) async {
    await showPage(
      tester,
      textScale: 2,
      respond: (_) async => jsonResponse({
        ...releaseJson(),
        'body': List.filled(60, '这是一段较长的更新说明，用于验证弹窗可以滚动阅读。').join('\n'),
      }),
    );
    final check = find.byKey(const ValueKey('about-check-update'));
    await tester.ensureVisible(check);
    await tester.tap(check);
    await tester.pumpAndSettle();
    expect(find.text('下载更新').hitTestable(), findsOneWidget);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: platforms);
}
