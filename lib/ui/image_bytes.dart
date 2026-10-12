import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../formats/image_format.dart';

class ImageBytes extends StatelessWidget {
  const ImageBytes(
    this.bytes, {
    super.key,
    this.fit = BoxFit.contain,
    this.errorBuilder,
  });
  final Uint8List bytes;
  final BoxFit fit;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;
  @override
  Widget build(BuildContext context) =>
      ImageFormat.mime(bytes) == 'image/svg+xml'
      ? SvgPicture.memory(bytes, fit: fit, errorBuilder: errorBuilder)
      : Image.memory(bytes, fit: fit, errorBuilder: errorBuilder);
}
