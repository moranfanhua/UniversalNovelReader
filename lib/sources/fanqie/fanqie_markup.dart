import 'dart:convert';
import '../comment_source.dart';

/// Official App CommentContent / ImageDataList and emoji_config.json formats.
class FanqieMarkup {
  static const _prefix = '\u0000fanqie:';
  static const emojiNames = [
    '[微笑]',
    '[偷笑]',
    '[笑]',
    '[什么]',
    '[害羞]',
    '[爱慕]',
    '[飞吻]',
    '[奸笑]',
    '[尬笑]',
    '[思考]',
    '[撇嘴]',
    '[做鬼脸]',
    '[酷]',
    '[翻白眼]',
    '[惊呆]',
    '[震惊]',
    '[送心]',
    '[委屈]',
    '[快哭了]',
    '[笑哭]',
    '[哭]',
    '[大笑]',
    '[舔屏]',
    '[怒]',
    '[捂脸]',
    '[吐]',
    '[恐惧]',
    '[抓狂]',
    '[敬礼]',
    '[石化]',
    '[OK]',
    '[赞]',
    '[爱心]',
    '[伤心]',
    '[KISS]',
    '[懂了]',
    '[探究]',
    '[重拳出击]',
    '[吃瓜]',
    '[盯]',
    '[你细品]',
    '[赶稿中]',
    '[注意]',
    '[饱了]',
    '[码住]',
    '[学会了]',
    '[顶帖]',
    '[求爆更]',
    '[求关注]',
    '[我也强推]',
    '[雀食神作]',
    '[已种草]',
    '[书架加一]',
  ];
  static final _emojiAssets = {
    for (var i = 0; i < emojiNames.length; i++)
      emojiNames[i]:
          'assets/fanqie_emoji/emoji_${(i + 1).toString().padLeft(2, '0')}.webp',
  };
  static final _tokens = RegExp(r'\[[A-Z\u4e00-\u9fa5]+\]');

  static String? _address(Object? value) =>
      value is String ? commentImageAddress(value) : null;

  static String? _image(Object? value) {
    if (value is String) return _address(value);
    if (value is! Map) return null;
    // Prefer animation when supplied. Never reconstruct signed CDN URLs.
    for (final key in [
      'dynamic_url',
      'web_url',
      'url',
      'image_url',
      'web_uri',
    ]) {
      final address = _address(value[key]);
      if (address != null) return address;
    }
    final thumbs = value['thumb_nails'];
    if (thumbs is List) {
      for (final thumb in thumbs.whereType<Map>()) {
        for (final key in ['dynamic_url', 'web_url']) {
          final address = _address(thumb[key]);
          if (address != null) return address;
        }
      }
    }
    return null;
  }

  static String encode(Map data) {
    final text = '${data['text'] ?? ''}';
    final imageList = data['image_data_list'];
    final images = imageList is Map ? imageList['image_data'] : imageList;
    final urls = <String>[];
    for (final list in [images, data['image_data'], data['image_url']]) {
      if (list is! List) continue;
      urls.addAll(list.map(_image).whereType<String>());
      if (urls.isNotEmpty) break;
    }
    final extensions = <Map<String, dynamic>>[];
    final rawExtensions = data['text_exts'];
    if (rawExtensions is List) {
      for (final ext in rawExtensions.whereType<Map>()) {
        // Other extensions (mentions, links, book cards, etc.) retain their
        // original visible text. App URI schemes are never opened by the UI.
        if (ext['tp'] != 3) continue;
        final address = _image(ext['image_data']) ?? _address(ext['uri']);
        final start = ext['s'], end = ext['e'];
        if (address == null || start is! int || end is! int) continue;
        extensions.add({'s': start, 'e': end, 'image': address});
      }
    }
    if (urls.isEmpty && extensions.isEmpty) return text;
    return '$_prefix${jsonEncode({'text': text, 'images': urls.toSet().toList(), if (extensions.isNotEmpty) 'text_exts': extensions})}';
  }

  static List<CommentPart> _text(String text) {
    final parts = <CommentPart>[];
    var offset = 0;
    for (final match in _tokens.allMatches(text)) {
      if (match.start > offset) {
        parts.add(CommentPart.text(text.substring(offset, match.start)));
      }
      final asset = _emojiAssets[match[0]];
      parts.add(
        asset == null
            ? CommentPart.text(match[0]!)
            : CommentPart.asset(asset, text: match[0]!),
      );
      offset = match.end;
    }
    if (offset < text.length) {
      parts.add(CommentPart.text(text.substring(offset)));
    }
    return parts;
  }

  static bool _boundary(String text, int offset) =>
      offset == 0 ||
      offset == text.length ||
      !(text.codeUnitAt(offset - 1) >= 0xd800 &&
          text.codeUnitAt(offset - 1) <= 0xdbff &&
          text.codeUnitAt(offset) >= 0xdc00 &&
          text.codeUnitAt(offset) <= 0xdfff);

  static List<CommentPart> content(String encoded) {
    if (!encoded.startsWith(_prefix)) return _text(encoded);
    final Map data;
    try {
      final decoded = jsonDecode(encoded.substring(_prefix.length));
      if (decoded is! Map) return _text(encoded);
      data = decoded;
    } on FormatException {
      return _text(encoded);
    }
    final text = '${data['text'] ?? ''}', parts = <CommentPart>[];
    final rawExtensions = data['text_exts'];
    final extensions = rawExtensions is List
        ? rawExtensions
              .whereType<Map>()
              .where((ext) => ext['s'] is int && ext['e'] is int)
              .toList()
        : <Map>[];
    extensions.sort((a, b) => (a['s'] as int).compareTo(b['s'] as int));
    final inlineImages = <String>{};
    var offset = 0;
    for (final ext in extensions) {
      final start = ext['s'] as int, end = ext['e'] as int;
      final image = _address(ext['image']);
      if (image == null ||
          start < offset ||
          end <= start ||
          end > text.length ||
          !_boundary(text, start) ||
          !_boundary(text, end)) {
        continue;
      }
      parts.addAll(_text(text.substring(offset, start)));
      parts.add(
        CommentPart.image(
          image,
          text: text.substring(start, end),
          inline: true,
        ),
      );
      inlineImages.add(image);
      offset = end;
    }
    parts.addAll(_text(text.substring(offset)));
    final images = data['images'];
    if (images is List) {
      for (final image in images) {
        final address = _address(image);
        if (address != null && !inlineImages.contains(address)) {
          parts.add(CommentPart.image(address));
        }
      }
    }
    return parts;
  }
}
