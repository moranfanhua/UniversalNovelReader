/// Image addresses used by the official comment renderer. Unknown tags remain
/// readable so unsupported packs or unavailable images do not erase content.
class SfacgMarkup {
  static final tags = RegExp(
    r'\[(em|sfem|dsfem):([A-Za-z0-9_-]+):([A-Za-z0-9_-]+)\]',
  );

  static String? imageUrl(RegExpMatch tag) {
    if (tag[1] == 'em') {
      final number = int.tryParse(tag[3]!);
      if (tag[2] != 'sfgirl' || number == null || number < 1 || number > 67) {
        return null;
      }
      return 'https://rs.sfacg.com/web/common/images/sfgirl/sfgirl${number.toString().padLeft(3, '0')}.png';
    }
    final extension = tag[1] == 'dsfem' ? 'gif' : 'png';
    return 'https://rss.sfacg.com/web/account/images/emoji/${tag[2]}/${tag[3]}.$extension';
  }

  static String? imageAddress(String value) {
    final uri = Uri.tryParse(value.startsWith('//') ? 'https:$value' : value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.replace(scheme: 'https').toString();
  }
}
