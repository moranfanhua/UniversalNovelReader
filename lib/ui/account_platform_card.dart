import 'package:flutter/material.dart';

import '../sources/account_source.dart';
import '../sources/session_validation.dart';
import '../sources/source_verification.dart';
import 'source_icon.dart';

const _accountNameStyle = TextStyle(
  fontSize: 20,
  height: 1.2,
  fontWeight: FontWeight.w600,
);
const _accountIdStyle = TextStyle(
  fontSize: 13,
  height: 1.2,
  color: Colors.white70,
);
const _metricValueStyle = TextStyle(
  fontSize: 26,
  height: 1.2,
  fontWeight: FontWeight.w600,
);
const _metricLabelStyle = TextStyle(
  fontSize: 12,
  height: 1.2,
  color: Colors.white60,
);

class AccountPlatformCard extends StatefulWidget {
  const AccountPlatformCard({
    super.key,
    required this.source,
    required this.onOpen,
  });

  final AccountSource source;
  final Future<void> Function() onOpen;

  @override
  State<AccountPlatformCard> createState() => _AccountPlatformCardState();
}

class _AccountPlatformCardState extends State<AccountPlatformCard> {
  Object? _session;
  SourceAccount? _account;
  String? _error;
  bool _loading = false;
  bool _opening = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AccountPlatformCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        _session != widget.source.accountSession) {
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final source = widget.source;
    final session = source.accountSession;
    setState(() {
      _session = session;
      _account = null;
      _error = null;
      _loading = session != null;
    });
    if (session == null) return;
    SourceAccount? account;
    String? error;
    try {
      account = await source.getAccount();
    } on SessionExpiredException {
      error = '登录已失效，点击卡片重新登录';
    } on SourceVerificationRequiredException {
      error = '需要平台安全验证，点击卡片处理';
    } catch (_) {
      error = '暂时无法读取账号信息';
    }
    if (!mounted || generation != _generation) return;
    if (source.accountSession != session) {
      _load();
      return;
    }
    setState(() {
      _account = account;
      _error = error;
      _loading = false;
    });
  }

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await widget.onOpen();
    } finally {
      if (mounted) {
        _opening = false;
        _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    final tint = switch (widget.source.id) {
      'qidian' => const Color(0xFFAB4A50),
      'fanqie' => const Color(0xFFB8623E),
      'ciweimao' => const Color(0xFF7970AD),
      _ => const Color(0xFF43899A),
    };
    return Semantics(
      label: widget.source.name,
      button: true,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(const Color(0xFF171D29), tint, 0.16)!,
                Color.lerp(const Color(0xFF171D29), tint, 0.5)!,
              ],
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                right: -48,
                top: 45,
                child: IgnorePointer(
                  child: Container(
                    width: 230,
                    height: 230,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.045),
                        width: 32,
                      ),
                    ),
                  ),
                ),
              ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _opening ? null : _open,
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(color: Colors.white),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          color: Colors.black.withValues(alpha: 0.18),
                          alignment: Alignment.centerLeft,
                          child: Tooltip(
                            message: widget.source.name,
                            child: SourceIcon(widget.source.id, size: 30),
                          ),
                        ),
                        _AccountCardBody(
                          child: _session == null
                              ? const Align(
                                  alignment: Alignment.centerLeft,
                                  heightFactor: 1,
                                  child: Text(
                                    '未登录',
                                    style: TextStyle(
                                      fontSize: 20,
                                      color: Colors.white70,
                                    ),
                                  ),
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (_loading)
                                      const Padding(
                                        padding: EdgeInsets.symmetric(
                                          vertical: 14,
                                        ),
                                        child: Row(
                                          children: [
                                            SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white70,
                                              ),
                                            ),
                                            SizedBox(width: 12),
                                            Expanded(child: Text('正在读取平台账号…')),
                                          ],
                                        ),
                                      ),
                                    if (account != null) ...[
                                      Row(
                                        children: [
                                          _AccountAvatar(
                                            address: account.avatar,
                                          ),
                                          const SizedBox(width: 14),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  account.name.trim().isEmpty
                                                      ? '平台账号'
                                                      : account.name,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: _accountNameStyle,
                                                ),
                                                const SizedBox(height: 4),
                                                Tooltip(
                                                  message: 'ID ${account.id}',
                                                  child: Text(
                                                    'ID ${account.id}',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: _accountIdStyle,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          const Icon(
                                            Icons.chevron_right,
                                            color: Colors.white70,
                                          ),
                                        ],
                                      ),
                                      if (account.metrics.isNotEmpty) ...[
                                        const SizedBox(height: 22),
                                        _AccountMetrics(
                                          metrics: account.metrics,
                                        ),
                                      ],
                                    ],
                                    if (_error != null ||
                                        account?.notice != null) ...[
                                      const SizedBox(height: 12),
                                      Text(
                                        _error ?? account!.notice!,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                        ),
                                      ),
                                      TextButton.icon(
                                        onPressed: _loading ? null : _load,
                                        style: TextButton.styleFrom(
                                          foregroundColor: Colors.white,
                                        ),
                                        icon: const Icon(
                                          Icons.refresh,
                                          size: 18,
                                        ),
                                        label: const Text('重试'),
                                      ),
                                    ],
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountCardBody extends StatelessWidget {
  const _AccountCardBody({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final scale = scaler.scale(14) / 14;
      // Reserve the same profile and three-metric area in every login state.
      // Extra rows keep large text readable on narrow screens.
      final columns = _AccountMetrics.columnsFor(
        constraints.maxWidth - 40,
        scale,
        3,
      );
      final rows = (3 / columns).ceil();
      double lineHeight(TextStyle style) =>
          scaler.scale(style.fontSize!) * style.height!;
      final profileHeight =
          (2 * lineHeight(_accountNameStyle) + 4 + lineHeight(_accountIdStyle))
              .clamp(54.0, double.infinity);
      final metricHeight =
          lineHeight(_metricValueStyle) + 2 + lineHeight(_metricLabelStyle);
      return ConstrainedBox(
        constraints: BoxConstraints(
          minHeight:
              (40 + profileHeight + 22 + rows * metricHeight + (rows - 1) * 16)
                  .ceilToDouble(),
        ),
        child: Padding(padding: const EdgeInsets.all(20), child: child),
      );
    },
  );
}

class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({required this.address});
  final String? address;

  @override
  Widget build(BuildContext context) {
    const fallback = Icon(
      Icons.person_outline,
      color: Colors.white70,
      size: 30,
    );
    return Container(
      width: 54,
      height: 54,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: address == null
          ? fallback
          : Image.network(
              address!,
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

class _AccountMetrics extends StatelessWidget {
  const _AccountMetrics({required this.metrics});
  final List<AccountMetric> metrics;

  static int columnsFor(double width, double scale, int count) =>
      (width / (82 * scale)).floor().clamp(1, count);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final columns = columnsFor(constraints.maxWidth, scale, metrics.length);
      final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 16,
        children: [
          for (final metric in metrics)
            SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Tooltip(
                    message: metric.value,
                    child: Text(
                      metric.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _metricValueStyle,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(metric.label, style: _metricLabelStyle),
                ],
              ),
            ),
        ],
      );
    },
  );
}
