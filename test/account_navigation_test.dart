import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/data/library.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_source.dart';
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/fanqie/fanqie_source.dart';
import 'package:unr/sources/qidian/qidian_api.dart';
import 'package:unr/sources/qidian/qidian_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/ui/account.dart';
import 'package:unr/ui/account_platform_card.dart';
import 'package:unr/ui/settings.dart';

void main() {
  Library library() {
    final sfacg = SfacgApi();
    final fanqie = FanqieApi();
    final qidian = QidianApi();
    final ciweimao = CiweimaoApi();
    final result = Library(
      Directory.systemTemp,
      SfacgSource(sfacg),
      novelSources: [
        CiweimaoSource(ciweimao),
        FanqieSource(fanqie),
        QidianSource(qidian),
      ],
    );
    addTearDown(result.dispose);
    addTearDown(sfacg.close);
    addTearDown(fanqie.close);
    addTearDown(qidian.close);
    addTearDown(ciweimao.close);
    return result;
  }

  testWidgets('账号和搜索设置始终按起点、番茄、刺猬猫、菠萝包排列', (tester) async {
    final data = library();
    const ids = ['qidian', 'fanqie', 'ciweimao', 'sfacg'];
    expect(data.searchSources.map((source) => source.id), ids);
    expect(data.enabledSearchSources.map((source) => source.id), ids);
    await tester.pumpWidget(
      MaterialApp(home: AccountSettingsPage(library: data)),
    );
    expect(
      tester
          .widgetList<AccountPlatformCard>(find.byType(AccountPlatformCard))
          .map((card) => card.source.name),
      ['起点读书', '番茄小说', '刺猬猫阅读', '菠萝包轻小说'],
    );
    expect(find.text('未登录'), findsNWidgets(4));
    for (final id in ids) {
      final card = find.byKey(ValueKey('account-card-$id'));
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.text('选择登录方式'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('导入会话'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('验证并保存会话'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(
      MaterialApp(
        home: SoftwareSettingsPage(
          library: data,
          gbk: false,
          onEncodingChanged: (_) {},
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('settings-search-entry')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .map((tile) => tile.key),
      ids.map((id) => ValueKey('search-source-$id')),
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [390.0, 1400.0]) {
    testWidgets('账号卡片在宽度 $width 始终竖排且高度一致', (tester) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: AccountSettingsPage(library: library())),
      );
      await tester.pumpAndSettle();
      final cards = find.byType(AccountPlatformCard);
      final first = tester.getRect(cards.at(0));
      var previous = first;
      for (var i = 1; i < 4; i++) {
        final current = tester.getRect(cards.at(i));
        expect(current.left, first.left);
        expect(current.width, first.width);
        expect(current.height, first.height);
        expect(current.top, greaterThan(previous.bottom));
        previous = current;
      }
      expect(tester.takeException(), isNull);
    });
  }
}
