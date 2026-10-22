/// Bounded, memory-only App read cache. Invalidating a request also prevents its
/// late result from replacing a newer entry; failed requests are never cached.
class QidianCache<T> {
  QidianCache({required this.lifetime, required this.clock});

  final Duration lifetime;
  final DateTime Function() clock;
  final _values = <String, ({DateTime at, T value})>{};
  final _pending = <String, Future<T>>{};

  Future<T> get(String key, Future<T> Function() load, {bool refresh = false}) {
    if (refresh) invalidate(key);
    final cached = _values[key];
    if (cached != null) {
      final age = clock().difference(cached.at);
      if (!age.isNegative && age < lifetime) return Future.value(cached.value);
      _values.remove(key);
    }
    return _pending.putIfAbsent(key, () {
      late Future<T> task;
      task = Future<T>.sync(load)
          .then((value) {
            if (identical(_pending[key], task)) {
              _values[key] = (at: clock(), value: value);
              if (_values.length > 64) _values.remove(_values.keys.first);
            }
            return value;
          })
          .whenComplete(() {
            if (identical(_pending[key], task)) _pending.remove(key);
          });
      return task;
    });
  }

  void invalidate(String key) {
    _values.remove(key);
    _pending.remove(key);
  }

  void clear() {
    _values.clear();
    _pending.clear();
  }
}
