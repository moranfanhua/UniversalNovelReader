import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:unr/data/library.dart';
import 'package:unr/main.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/account.dart';
import 'package:unr/ui/settings.dart';

class MyMemoryLibrary extends Library {
  MyMemoryLibrary()
    : super(
        Directory.systemTemp,
        SfacgSource(
          SfacgApi(
            client: MockClient((_) async => throw StateError('导航不应发起网络请求')),
          ),
        ),
      );

  @override
  Future<void> save() async => notifyListeners();
}

void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });

  void configureViewport(WidgetTester tester) {
    tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
        ? const Size(1400, 900)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('三个底部入口，账号按平台进入并逐级返回', (tester) async {
    configureViewport(tester);
    final library = MyMemoryLibrary();
    library.source.api.setCookie(
      '.SFCommunity=synthetic; session_APP=synthetic-session',
    );
    final cookies = Map<String, String>.from(library.source.api.cookies);
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await tester.pumpWidget(UnrApp(library: library));

    expect(
      tester
          .widgetList<NavigationDestination>(find.byType(NavigationDestination))
          .map((item) => item.label),
      ['书库', '书源', '我的'],
    );
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    expect(find.text('账号设置'), findsOneWidget);
    expect(find.text('软件设置'), findsOneWidget);
    expect(find.byType(AccountPage), findsNothing);
    expect(find.byType(SettingsPage), findsNothing);

    await tester.tap(find.text('账号设置'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text('菠萝包轻小说'), findsOneWidget);
    expect(find.textContaining('起点'), findsNothing);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<AssetImage>());
    expect((image.image as AssetImage).assetName, 'assets/sfacg_icon.jpg');

    await tester.tap(find.text('菠萝包轻小说'));
    await tester.pumpAndSettle();
    expect(find.text('已保存登录会话'), findsOneWidget);
    expect(find.text('登录菠萝包'), findsOneWidget);
    expect(find.text('导入 App 会话'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('菠萝包轻小说'), findsOneWidget);
    expect(find.byType(AccountPage), findsNothing);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      2,
    );
    expect(find.text('软件设置'), findsOneWidget);
    expect(library.source.api.cookies, cookies);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  testWidgets('软件设置保留原有偏好，编码开关立即更新且返回重开后保持', (tester) async {
    configureViewport(tester);
    final library = MyMemoryLibrary();
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await tester.pumpWidget(UnrApp(library: library));
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('软件设置'));
    await tester.pumpAndSettle();
    expect(find.text('书架排序'), findsOneWidget);
    expect(find.text('阅读偏好'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(
      find.byKey(const ValueKey('reading-volume-keys')),
      defaultTargetPlatform == TargetPlatform.android
          ? findsOneWidget
          : findsNothing,
    );
    await tester.tap(find.text('翻页阅读'));
    await tester.pumpAndSettle();
    expect(library.readingMode, ReadingMode.paged);

    final settingsList = find.descendant(
      of: find.byType(SettingsPage),
      matching: find.byType(ListView),
    );
    final encoding = find.widgetWithText(SwitchListTile, '按 GBK 编码导入 TXT');
    await tester.drag(settingsList, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(encoding).value, isFalse);
    await tester.tap(encoding);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(encoding).value, isTrue);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书库'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('软件设置'));
    await tester.pumpAndSettle();
    expect(library.readingMode, ReadingMode.paged);
    await tester.drag(settingsList, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(encoding).value, isTrue);
    await tester.tap(encoding);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(encoding).value, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);
}
