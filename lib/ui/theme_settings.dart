import 'package:flutter/material.dart';
import '../data/library.dart';

class ThemeSettings extends StatefulWidget {
  const ThemeSettings({super.key, required this.library});
  final Library library;

  @override
  State<ThemeSettings> createState() => _ThemeSettingsState();
}

class _ThemeSettingsState extends State<ThemeSettings> {
  bool saving = false;
  String? error;

  Future<void> _select(AppThemeMode mode) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.library.setThemeMode(mode);
    } catch (e) {
      if (mounted) setState(() => error = '显示模式保存失败：$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.library,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('显示模式'),
        DropdownButton<AppThemeMode>(
          key: const ValueKey('theme-mode'),
          value: widget.library.themeMode,
          isExpanded: true,
          items: const [
            DropdownMenuItem(value: AppThemeMode.system, child: Text('跟随系统')),
            DropdownMenuItem(value: AppThemeMode.light, child: Text('日间模式')),
            DropdownMenuItem(value: AppThemeMode.dark, child: Text('夜间模式')),
          ],
          onChanged: saving
              ? null
              : (mode) {
                  if (mode != null) _select(mode);
                },
        ),
        const Text('应用内所有页面与阅读器共用此设置。'),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
  );
}
