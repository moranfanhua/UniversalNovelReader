import 'package:flutter/material.dart';
import '../data/library.dart';
import 'reading_settings.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.library,
    required this.gbk,
    required this.onEncodingChanged,
  });
  final Library library;
  final bool gbk;
  final ValueChanged<bool> onEncodingChanged;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 660),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('阅读偏好', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          ReadingSettings(library: library),
          const Divider(height: 40),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('按 GBK 编码导入 TXT'),
            subtitle: const Text('默认识别 UTF-8 / UTF-16 文本'),
            value: gbk,
            onChanged: onEncodingChanged,
          ),
        ],
      ),
    ),
  );
}
