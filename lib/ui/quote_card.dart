import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../domain/models.dart';
import '../formats/image_format.dart';

enum QuoteCardTheme {
  paper('暖纸', Color(0xfff4efe5), Color(0xff302b27), Color(0xff9b6249)),
  green('青绿', Color(0xffe8efea), Color(0xff233c34), Color(0xff497966)),
  night('夜色', Color(0xff242d3b), Color(0xfff1ebdf), Color(0xffd4b68b));

  const QuoteCardTheme(this.label, this.background, this.ink, this.accent);
  final String label;
  final Color background, ink, accent;
}

Future<ui.Image> decodeQuoteCover(Uint8List bytes) async {
  if (ImageFormat.mime(bytes) == 'image/svg+xml') {
    final info = await vg.loadPicture(SvgBytesLoader(bytes), null);
    try {
      // Bound SVG rasterization just as the bitmap codec bounds cover decoding.
      final scale = 600 / math.max(info.size.width, info.size.height);
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
        ..scale(scale)
        ..drawPicture(info.picture);
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(
          math.max(1, (info.size.width * scale).round()),
          math.max(1, (info.size.height * scale).round()),
        );
      } finally {
        picture.dispose();
      }
    } finally {
      info.picture.dispose();
    }
  }
  final codec = await ui.instantiateImageCodecWithSize(
    await ui.ImmutableBuffer.fromUint8List(bytes),
    getTargetSize: (width, height) {
      final scale = math.min(1.0, math.min(400 / width, 600 / height));
      return ui.TargetImageSize(
        width: math.max(1, (width * scale).round()),
        height: math.max(1, (height * scale).round()),
      );
    },
  );
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// Renders the entire card independently of the preview's viewport and text scale.
/// Preview, saving and system sharing all use these same PNG bytes.
Future<Uint8List> renderQuoteCard({
  required Book book,
  required String quote,
  required QuoteCardTheme theme,
  ui.Image? cover,
  String? fontFamily,
}) async {
  if (quote.trim().isEmpty) throw const SourceException('请先选择需要分享的正文');
  const width = 480.0, padding = 38.0, ratio = 2.25;
  final painters = <TextPainter>[];
  TextPainter text(
    String value,
    double size,
    Color color,
    double maxWidth, {
    FontWeight weight = FontWeight.normal,
    double height = 1.6,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: size,
          color: color,
          height: height,
          fontWeight: weight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    painters.add(painter);
    return painter;
  }

  try {
    final body = text(
      quote.trim(),
      22,
      theme.ink,
      width - padding * 2,
      height: 1.85,
    );
    final title = text(
      '《${book.title}》',
      17,
      theme.ink,
      314,
      weight: FontWeight.w600,
      height: 1.45,
    );
    final author = text(
      '${book.author.trim().isEmpty ? '佚名' : book.author} 著',
      13,
      theme.ink.withValues(alpha: .7),
      314,
    );
    const bodyTop = 72.0;
    final dividerY = bodyTop + body.height + 36;
    final bookY = dividerY + 28;
    final height =
        bookY + math.max(96, title.height + author.height + 14) + padding;
    if (height > 6400) {
      throw const SourceException('选句过长，图片将超出尺寸限制，请缩短选句后重试');
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, height),
      Paint()..color = theme.background,
    );
    text(
      '“',
      65,
      theme.accent.withValues(alpha: .5),
      80,
      height: 1,
    ).paint(canvas, const Offset(padding - 4, 23));
    body.paint(canvas, const Offset(padding, bodyTop));
    canvas.drawLine(
      Offset(padding, dividerY),
      Offset(width - padding, dividerY),
      Paint()
        ..color = theme.accent.withValues(alpha: .25)
        ..strokeWidth = 1,
    );

    final coverRect = Rect.fromLTWH(padding, bookY, 64, 96);
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(coverRect, const Radius.circular(4)),
    );
    if (cover != null) {
      paintImage(
        canvas: canvas,
        rect: coverRect,
        image: cover,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
      );
    } else {
      canvas.drawRect(
        coverRect,
        Paint()..color = theme.accent.withValues(alpha: .16),
      );
      canvas.drawRect(
        Rect.fromLTWH(padding + 5, bookY, 2, 96),
        Paint()..color = theme.accent.withValues(alpha: .3),
      );
      text(
        'UNR',
        12,
        theme.accent,
        44,
      ).paint(canvas, Offset(padding + 14, bookY + 22));
      text(
        '阅读',
        15,
        theme.accent,
        44,
        weight: FontWeight.w600,
      ).paint(canvas, Offset(padding + 14, bookY + 45));
    }
    canvas.restore();
    title.paint(canvas, Offset(padding + 90, bookY + 2));
    author.paint(canvas, Offset(padding + 90, bookY + title.height + 12));
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(
        (width * ratio).round(),
        (height * ratio).ceil(),
      );
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw const SourceException('图片生成失败，请重试');
        return data.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  } finally {
    for (final painter in painters) {
      painter.dispose();
    }
  }
}

String quoteCardFileName(Book book) {
  final title = book.title
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .trim();
  final short = title.runes.take(60).toList();
  return '${short.isEmpty ? '阅读' : String.fromCharCodes(short)}_选句.png';
}
