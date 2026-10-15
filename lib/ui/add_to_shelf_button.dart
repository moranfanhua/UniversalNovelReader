import 'package:flutter/material.dart';
import '../data/library.dart';
import '../domain/models.dart';

class AddToShelfButton extends StatefulWidget {
  const AddToShelfButton({
    super.key,
    required this.library,
    required this.book,
    this.compact = false,
    this.enabled = true,
  });
  final Library library;
  final Book book;
  final bool compact, enabled;

  @override
  State<AddToShelfButton> createState() => _AddToShelfButtonState();
}

class _AddToShelfButtonState extends State<AddToShelfButton> {
  bool saving = false;

  Future<void> _add() async {
    if (saving || widget.library.isOnShelf(widget.book)) return;
    setState(() => saving = true);
    try {
      await widget.library.add(widget.book);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加入书架失败：$e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.library,
    builder: (context, _) {
      final added = widget.library.isOnShelf(widget.book);
      final label = saving
          ? '正在加入书架'
          : added
          ? '已加入书架'
          : '加入书架';
      final icon = Icon(
        added ? Icons.bookmark_added_outlined : Icons.bookmark_add_outlined,
      );
      final onPressed = saving || added || !widget.enabled ? null : _add;
      return widget.compact
          ? IconButton(tooltip: label, onPressed: onPressed, icon: icon)
          : OutlinedButton.icon(
              onPressed: onPressed,
              icon: icon,
              label: Text(label),
            );
    },
  );
}
