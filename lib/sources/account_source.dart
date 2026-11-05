import 'novel_source.dart';

/// Read-only account information from the platform's official App API.
abstract interface class AccountSource implements NovelSource {
  /// An opaque snapshot used to discard results after login or logout.
  Object? get accountSession;
  Future<SourceAccount> getAccount();
}

class SourceAccount {
  const SourceAccount({
    required this.id,
    required this.name,
    this.avatar,
    this.metrics = const [],
    this.notice,
  });

  final String id, name;
  final String? avatar, notice;
  final List<AccountMetric> metrics;
}

class AccountMetric {
  const AccountMetric(this.label, this.value);

  factory AccountMetric.count(String label, Object? raw) {
    final value = raw is int || raw is String ? BigInt.tryParse('$raw') : null;
    return AccountMetric(
      label,
      value != null && !value.isNegative ? '$value' : '—',
    );
  }

  final String label, value;
}

String? accountAvatar(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  final uri = Uri.tryParse(raw.startsWith('//') ? 'https:$raw' : raw);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.replace(scheme: 'https').toString();
}
