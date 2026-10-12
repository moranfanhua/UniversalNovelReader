import 'dart:convert';
import 'package:xml/xml.dart';

class ImageFormat {
  static String? mime(List<int> bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 137 &&
        bytes[1] == 80 &&
        bytes[2] == 78 &&
        bytes[3] == 71) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255) {
      return 'image/jpeg';
    }
    if (bytes.length >= 6 &&
        (ascii.decode(bytes.take(6).toList(), allowInvalid: true) == 'GIF87a' ||
            ascii.decode(bytes.take(6).toList(), allowInvalid: true) ==
                'GIF89a')) {
      return 'image/gif';
    }
    try {
      if (XmlDocument.parse(utf8.decode(bytes)).rootElement.name.local ==
          'svg') {
        return 'image/svg+xml';
      }
    } catch (_) {
      /* Raster images are not XML. */
    }
    return null;
  }

  static String extension(String mime) => const {
    'image/png': 'png',
    'image/jpeg': 'jpg',
    'image/gif': 'gif',
    'image/svg+xml': 'svg',
  }[mime]!;
}
