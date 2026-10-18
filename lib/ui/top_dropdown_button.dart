import 'package:flutter/material.dart';

/// A selector whose menu always opens at the first item.
class TopDropdownButton<T> extends StatelessWidget {
  const TopDropdownButton({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.menuMaxHeight = 320,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final double menuMaxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = items.firstWhere((item) => item.value == value);
    final enabled = onChanged != null;
    return LayoutBuilder(
      builder: (context, constraints) => PopupMenuButton<T>(
        // Supplying initialValue would align and scroll to the selected item.
        position: PopupMenuPosition.under,
        enabled: enabled,
        tooltip: '展开选项',
        constraints: BoxConstraints(
          minWidth: constraints.maxWidth,
          maxWidth: constraints.maxWidth,
          maxHeight: menuMaxHeight,
        ),
        onSelected: onChanged,
        itemBuilder: (context) => [
          for (final item in items)
            PopupMenuItem<T>(
              value: item.value,
              enabled: item.enabled,
              child: Semantics(
                selected: item.value == value,
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    color: item.value == value
                        ? theme.colorScheme.primary
                        : null,
                  ),
                  child: item.child,
                ),
              ),
            ),
        ],
        child: DefaultTextStyle(
          style: theme.textTheme.titleMedium!.copyWith(
            color: enabled ? null : theme.disabledColor,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          child: Container(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            child: Row(
              children: [
                Expanded(child: selected.child),
                Icon(
                  Icons.arrow_drop_down,
                  color: enabled ? null : theme.disabledColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
