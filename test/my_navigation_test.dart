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
    expect(find.text('选择登录方式'), findsOneWidget);
    expect(find.text('账号密码登录'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
    await tester.tap(find.text('账号密码登录'));
    await tester.pumpAndSettle();
    expect(find.text('登录菠萝包'), findsOneWidget);
    expect(find.text('导入 App 会话'), findsOneWidget);
    expect(find.text('打开官网登录'), findsNothing);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
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

  testWidgets('软件设置按分类进入并逐级返回，偏好和编码选择保留', (tester) async {
    configureViewport(tester);
    final library = MyMemoryLibrary();
    addTearDown(library.dispose);
    addTearDown(library.source.api.close);
    await tester.pumpWidget(UnrApp(library: library));
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('软件设置'));
    await tester.pumpAndSettle();
    expect(find.text('书架排序'), findsNothing);
    expect(find.byType(TabBar), findsNothing);
    expect(find.byType(TabBarView), findsNothing);
    expect(
      tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((tile) => (tile.title! as Text).data),
      ['书架', '阅读', '搜索', '导入', '日志'],
    );
    expect(find.text('阅读方式'), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-reading-entry')));
    await tester.pumpAndSettle();
    expect(find.text('阅读设置'), findsOneWidget);
    expect(find.text('阅读方式'), findsOneWidget);
    expect(find.text('书架排序').hitTestable(), findsNothing);
    expect(
      find.byKey(const ValueKey('reading-volume-keys')),
      defaultTargetPlatform == TargetPlatform.android
          ? findsOneWidget
          : findsNothing,
    );
    await tester.tap(find.text('翻页阅读'));
    await tester.pumpAndSettle();
    expect(library.readingMode, ReadingMode.paged);
    await tester.tap(find.byKey(const ValueKey('reading-paragraph-comments')));
    await tester.pumpAndSettle();
    expect(library.showParagraphComments, isFalse);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('软件设置'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-import-entry')));
    await tester.pumpAndSettle();
    expect(find.text('导入设置'), findsOneWidget);
    final encoding = find.widgetWithText(SwitchListTile, '按 GBK 编码导入 TXT');
    expect(tester.widget<SwitchListTile>(encoding).value, isFalse);
    await tester.tap(encoding);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(encoding).value, isTrue);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书库'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('软件设置'));
    await tester.pumpAndSettle();
    expect(library.readingMode, ReadingMode.paged);
    expect(library.showParagraphComments, isFalse);
    await tester.tap(find.byKey(const ValueKey('settings-import-entry')));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(encoding).value, isTrue);
    await tester.tap(encoding);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(encoding).value, isFalse);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-shelf-entry')));
    await tester.pumpAndSettle();
    expect(find.text('书架设置'), findsOneWidget);
    expect(find.text('书架排序').hitTestable(), findsOneWidget);
    expect(encoding.hitTestable(), findsNothing);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    final logsEntry = find.byKey(const ValueKey('settings-logs-entry'));
    await tester.ensureVisible(logsEntry);
    await tester.tap(logsEntry);
    await tester.pumpAndSettle();
    expect(find.text('导出日志'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('软件设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);
}
