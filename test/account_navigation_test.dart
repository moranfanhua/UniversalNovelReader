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
          .widgetList<ListTile>(find.byType(ListTile))
          .map((tile) => (tile.title! as Text).data),
      ['起点读书', '番茄小说', '刺猬猫阅读', '菠萝包轻小说'],
    );
    for (final name in ['起点读书', '番茄小说', '刺猬猫阅读', '菠萝包轻小说']) {
      await tester.tap(find.text(name));
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
}
