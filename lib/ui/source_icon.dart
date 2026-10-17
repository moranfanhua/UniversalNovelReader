import 'package:flutter/material.dart';

class SourceIcon extends StatelessWidget {
  const SourceIcon(this.source, {super.key, this.size = 44});
  final String source;
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = switch (source) {
      'sfacg' => 'assets/sfacg_icon.jpg',
      'fanqie' => 'assets/fanqie_icon.webp',
      'ciweimao' => 'assets/ciweimao_icon.png',
      _ => null,
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: asset != null
          ? Image.asset(
              asset,
              width: size,
              height: size,
              excludeFromSemantics: true,
            )
          : SizedBox(
              width: size,
              height: size,
              child: Icon(
                Icons.auto_stories,
                color: source == 'qidian' ? Colors.red : null,
              ),
            ),
    );
  }
}
