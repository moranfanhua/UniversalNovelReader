import 'package:flutter/foundation.dart';
import '../domain/models.dart';

/// Bounded idle states, with live listeners and pending writes pinned.
/// Evicted notifiers are left to GC: callers may still hold an unlistened value.
/// Disposing them here would make a late callback or listener unsafe.
class CommentLikeCache {
  CommentLikeCache({this.capacity = 256, this.onEvict, this.isPending})
    : assert(capacity > 0);

  final int capacity;
  final void Function(String)? onEvict;
  final bool Function(String)? isPending;
  final _entries = <String, CommentLikeNotifier>{};
  int get length => _entries.length;
  Iterable<CommentLikeNotifier> get values => _entries.values.toList();

  CommentLikeNotifier? operator [](String key) {
    final state = _entries.remove(key);
    if (state != null) _entries[key] = state;
    return state;
  }

  CommentLikeNotifier putIfAbsent(
    String key,
    CommentLikeNotifier Function() create,
  ) {
    final state = this[key] ?? create();
    _entries[key] = state;
    state.onIdle = trim;
    trim(except: key);
    return state;
  }

  void trim({String? except}) {
    var idle = _entries.entries.where((entry) => !_pinned(entry)).length;
    if (idle <= capacity) return;
    for (final key in _entries.keys.toList()) {
      final entry = MapEntry(key, _entries[key]!);
      if (key == except || _pinned(entry)) continue;
      final state = _entries.remove(key)!;
      state.onIdle = null;
      onEvict?.call(key);
      if (--idle <= capacity) break;
    }
  }

  bool _pinned(MapEntry<String, CommentLikeNotifier> entry) =>
      entry.value.inUse || (isPending?.call(entry.key) ?? false);
}

class CommentLikeNotifier extends ValueNotifier<CommentLikeStatus> {
  CommentLikeNotifier(super.value);
  VoidCallback? onIdle;
  bool get inUse => hasListeners || value.sending;

  @override
  set value(CommentLikeStatus next) {
    super.value = next;
    if (!inUse) onIdle?.call();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!inUse) onIdle?.call();
  }
}
