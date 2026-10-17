import '../comment_source.dart';
import 'ciweimao_parser.dart';

/// Official Android 2.9.367 EmojiData order and SpanUtilss token syntax.
class CiweimaoMarkup {
  static const emojiNames = [
    '滑稽',
    '可爱',
    '你懂的',
    '呕',
    '蓝瘦',
    '衰',
    '晕',
    '羞',
    '生气',
    '可怕',
    '哈哈',
    '星星眼',
    '汗',
    '吓',
    '流泪',
    '骂人',
    '笑哭',
    '墨镜',
    '爱你呦',
    '坏笑',
    '黑线',
    'kira',
    '口水',
    '闭嘴',
    '再见',
    '卖萌',
    '问号',
    '诶嘿嘿',
    '锤子',
    '敲可爱',
    '快哭了',
    '打哈欠',
    '猫饼干',
    '代币',
    '辣条',
    '胖次',
    '咸鱼',
    '海豹',
    '推荐票',
    '月票',
  ];
  static final _assets = {
    for (var i = 0; i < emojiNames.length; i++)
      '#(${emojiNames[i]})':
          'assets/ciweimao_emoji/emoji_${(i + 1).toString().padLeft(2, '0')}.png',
  };
  static final _tags = RegExp(r'\[img\]([^\[\]]+)\[/img\]|#\([^()\r\n]*\)');

  static List<CommentPart> content(String text) {
    final parts = <CommentPart>[];
    var offset = 0;
    for (final match in _tags.allMatches(text)) {
      if (match.start > offset) {
        parts.add(CommentPart.text(text.substring(offset, match.start)));
      }
      final token = match[0]!;
      final asset = _assets[token];
      final address = match[1] == null
          ? null
          : CiweimaoParser.imageAddress(match[1]!.trim());
      parts.add(
        asset != null
            ? CommentPart.asset(asset, text: token)
            : address != null
            ? CommentPart.image(address)
            : CommentPart.text(token),
      );
      offset = match.end;
    }
    if (offset < text.length) {
      parts.add(CommentPart.text(text.substring(offset)));
    }
    return parts;
  }
}
