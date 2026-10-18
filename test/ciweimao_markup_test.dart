import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_markup.dart';
import 'package:unr/sources/ciweimao/ciweimao_source.dart';
import 'package:unr/ui/comment_content.dart';
import 'package:unr/ui/comment_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('官方 40 个表情名称按 APK 顺序对应本地图片，资源均可加载', () async {
    expect(CiweimaoMarkup.emojiNames, hasLength(40));
    final paths = <String>{};
    for (final name in CiweimaoMarkup.emojiNames) {
      final part = CiweimaoMarkup.content('#($name)').single;
      expect(part.inline, isTrue);
      expect(part.text, '#($name)');
      expect(part.image, isNull);
      paths.add(part.asset!);
      final bytes = await rootBundle.load(part.asset!);
      expect(bytes.lengthInBytes, greaterThan(8));
      expect(bytes.buffer.asUint8List(bytes.offsetInBytes, 8), [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ]);
    }
    expect(paths, hasLength(40));
    expect(
      CiweimaoMarkup.content('#(滑稽)').single.asset,
      'assets/ciweimao_emoji/emoji_01.png',
    );
    expect(
      CiweimaoMarkup.content('#(kira)').single.asset,
      'assets/ciweimao_emoji/emoji_22.png',
    );
    expect(
      CiweimaoMarkup.content('#(月票)').single.asset,
      'assets/ciweimao_emoji/emoji_40.png',
    );
  });

  test('内置表情、配图与文字保留原顺序，未知及非法标记不丢失', () {
    const unknown = '#(未收录)#(../private)[img]file:///private[/img]';
    final parts = CiweimaoMarkup.content(
      '前#(滑稽)#(可爱)中[img]http://example.test/a.png[/img]后$unknown',
    );
    expect(parts.map((p) => p.asset ?? p.image ?? p.text), [
      '前',
      'assets/ciweimao_emoji/emoji_01.png',
      'assets/ciweimao_emoji/emoji_02.png',
      '中',
      'https://example.test/a.png',
      '后',
      '#(未收录)',
      '#(../private)',
      '[img]file:///private[/img]',
    ]);
    expect(parts[4].inline, isFalse);
    expect(CiweimaoMarkup.content('普通文字').single.text, '普通文字');
    expect(CiweimaoMarkup.content('未闭合#(滑稽').single.text, '未闭合#(滑稽');
  });

  testWidgets('评论和回复共用刺猬猫解析，内置表情离线显示并可放大', (tester) async {
    final api = CiweimaoApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommentText('前#(滑稽)后#(月票)', source: CiweimaoSource(api)),
        ),
      ),
    );
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, hasLength(2));
    expect(images.every((i) => i.image is AssetImage), isTrue);
    await tester.runAsync(() async {
      for (final image in images) {
        await precacheImage(
          image.image,
          tester.element(find.byType(CommentText)),
        );
      }
    });
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(CommentImage).first), const Size(32, 32));
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    await tester.tap(find.byType(CommentImage).first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(
      tester
          .widgetList<Image>(find.byType(Image))
          .every((i) => i.image is AssetImage),
      isTrue,
    );
    await tester.tap(find.byTooltip('关闭图片'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
