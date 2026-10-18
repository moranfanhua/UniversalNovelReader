import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/sources/fanqie/fanqie_markup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('App 嵌套图集保留顺序，动态表情优先，签名地址不改写', () {
    const animated =
        'https://cdn.example/a.awebp?x-signature=a%2Bb&x-expires=1';
    final parts = FanqieMarkup.content(
      FanqieMarkup.encode({
        'text': '图评[笑]😀[未知表情]',
        'image_data_list': {
          'image_data': [
            {
              'web_url': 'https://cdn.example/static.jpg',
              'dynamic_url': animated,
            },
            {'web_url': '//cdn.example/photo.webp'},
            {
              'dynamic_url': 'javascript:bad',
              'web_url': 'https://cdn.example/safe.png',
            },
            {'web_uri': 'tos-cn/object-id'},
            {'url': 'file:///private'},
            {
              'thumb_nails': [
                {'web_url': 'https://cdn.example/thumb.png'},
              ],
            },
          ],
        },
      }),
    );
    expect(parts.where((p) => p.image != null).map((p) => p.image), [
      animated,
      'https://cdn.example/photo.webp',
      'https://cdn.example/safe.png',
      'https://cdn.example/thumb.png',
    ]);
    expect(parts.where((p) => p.asset != null).single.text, '[笑]');
    expect(parts.map((p) => p.text).join(), '图评[笑]😀[未知表情]');
  });

  test('最新段评兼容 image_data 和 image_url，旧图评编码仍可读取', () {
    for (final fields in [
      {
        'image_data': [
          {'web_url': 'https://cdn.example/photo.jpg'},
        ],
      },
      {
        'image_url': ['https://cdn.example/photo.jpg'],
      },
      {
        'image_data_list': [
          {'url': 'https://cdn.example/photo.jpg'},
        ],
      },
    ]) {
      final parts = FanqieMarkup.content(
        FanqieMarkup.encode({'text': '图片', ...fields}),
      );
      expect(
        parts.where((p) => p.image != null).single.image,
        'https://cdn.example/photo.jpg',
      );
    }
    final old =
        '\u0000fanqie:${jsonEncode({
          'text': '旧图评[赞]',
          'images': ['https://cdn.example/old.gif'],
        })}';
    final parts = FanqieMarkup.content(old);
    expect(parts.last.image, 'https://cdn.example/old.gif');
    expect(parts.where((p) => p.asset != null).single.text, '[赞]');
  });

  test('富文本行内图片按 UTF-16 位置显示，提及和链接保留可见文字', () {
    final parts = FanqieMarkup.content(
      FanqieMarkup.encode({
        'text': '😀[图片]@读者 链接[赞]',
        'image_data_list': {
          'image_data': [
            {'web_url': 'https://cdn.example/inline.png'},
          ],
        },
        'text_exts': [
          {'s': 2, 'e': 6, 'tp': 3, 'uri': 'https://cdn.example/inline.png'},
          {'s': 6, 'e': 9, 'tp': 2, 'uri': 'dragon1967://user'},
          {'s': 10, 'e': 12, 'tp': 4, 'uri': 'https://example.com'},
        ],
      }),
    );
    final image = parts.where((p) => p.image != null).single;
    expect(image.inline, isTrue);
    expect(image.text, '[图片]');
    expect(parts.map((p) => p.text).join(), '😀[图片]@读者 链接[赞]');
  });

  test('无效位置和截断代理对的富文本不丢字或发起不安全图片请求', () {
    final parts = FanqieMarkup.content(
      FanqieMarkup.encode({
        'text': '😀原文[未知]',
        'text_exts': [
          {'s': 1, 'e': 2, 'tp': 3, 'uri': 'https://cdn.example/split.png'},
          {'s': -1, 'e': 2, 'tp': 3, 'uri': 'https://cdn.example/negative.png'},
          {'s': 0, 'e': 99, 'tp': 3, 'uri': 'https://cdn.example/outside.png'},
          {'s': 2, 'e': 4, 'tp': 3, 'uri': 'file:///private'},
          {'s': '2', 'e': 4, 'tp': 3, 'uri': 'https://cdn.example/bad.png'},
        ],
      }),
    );
    expect(parts.map((p) => p.text).join(), '😀原文[未知]');
    expect(parts.every((p) => p.image == null), isTrue);
    for (final encoded in ['\u0000fanqie:invalid', '\u0000fanqie:[]']) {
      expect(FanqieMarkup.content(encoded).map((p) => p.text).join(), encoded);
    }
  });

  test('53 个番茄基础表情使用 APK 对应本地资源并可实际解码', () async {
    expect(FanqieMarkup.emojiNames.length, 53);
    final parts = FanqieMarkup.content(FanqieMarkup.emojiNames.join());
    expect(parts.length, 53);
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      expect(part.inline, isTrue);
      expect(part.text, FanqieMarkup.emojiNames[i]);
      expect(
        part.asset,
        'assets/fanqie_emoji/emoji_${(i + 1).toString().padLeft(2, '0')}.webp',
      );
      final bytes = await rootBundle.load(part.asset!);
      final codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      final frame = await codec.getNextFrame();
      expect(frame.image.width, greaterThan(0));
      frame.image.dispose();
      codec.dispose();
    }
  });
}
