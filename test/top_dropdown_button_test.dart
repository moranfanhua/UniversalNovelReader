import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/ui/top_dropdown_button.dart';

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets('选择末项后再次展开仍从第一项开始（宽 $width，文字放大）', (tester) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var value = 19;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: StatefulBuilder(
                builder: (context, setState) => TopDropdownButton<int>(
                  value: value,
                  items: [
                    for (var i = 0; i < 20; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(
                          '选项$i ${'很长的选项名称' * 5}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (next) => setState(() => value = next!),
                ),
              ),
            ),
          ),
        ),
      );
      Finder item(int value) => find.byWidgetPredicate(
        (widget) => widget is PopupMenuItem<int> && widget.value == value,
      );
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.byType(TopDropdownButton<int>));
        await tester.pumpAndSettle();
        expect(item(0).hitTestable(), findsOneWidget);
        expect(item(19).hitTestable(), findsNothing);
        await tester.ensureVisible(item(19));
        await tester.pumpAndSettle();
        await tester.tap(item(19));
        await tester.pumpAndSettle();
        expect(value, 19);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('禁用选择框不能展开菜单', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TopDropdownButton<int>(
            value: 0,
            items: [DropdownMenuItem(value: 0, child: Text('当前选项'))],
            onChanged: null,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TopDropdownButton<int>));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<int>), findsNothing);
  });
}
