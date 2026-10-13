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
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: library,
    builder: (context, _) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('书架排序', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            DropdownButton<ShelfSort>(
              key: const ValueKey('shelf-sort'),
              value: library.shelfSort,
              isExpanded: true,
              items: [
                for (final sort in ShelfSort.values)
                  DropdownMenuItem(value: sort, child: Text(sort.label)),
              ],
              onChanged: (sort) async {
                if (sort == null) return;
                try {
                  await library.setShelfSort(sort);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('书架排序保存失败：$e')));
                  }
                }
              },
            ),
            Text(switch (library.shelfSort) {
              ShelfSort.updated => '按已获取的作品更新时间排序，本地小说按导入时间排序。',
              ShelfSort.name => '按名称升序排列。',
              ShelfSort.lastActive => '最近打开或阅读的作品优先。',
            }),
            const Divider(height: 40),
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
    ),
  );
}
