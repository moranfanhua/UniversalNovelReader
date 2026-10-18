import 'package:flutter/material.dart';

import '../sources/session_validation.dart';

class AccountSessionCheck extends StatefulWidget {
  const AccountSessionCheck({
    super.key,
    required this.session,
    required this.currentSession,
    required this.validate,
    this.enabled = true,
  });

  final Object? session;
  final Object? Function() currentSession;
  final Future<void> Function() validate;
  final bool enabled;

  @override
  State<AccountSessionCheck> createState() => _AccountSessionCheckState();
}

class _AccountSessionCheckState extends State<AccountSessionCheck> {
  int _generation = 0;
  bool _checking = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void didUpdateWidget(AccountSessionCheck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) _check();
  }

  Future<void> _check() async {
    final generation = ++_generation;
    final session = widget.session;
    setState(() {
      _checking = session != null;
      _result = null;
    });
    if (session == null) return;
    String result;
    try {
      await widget.validate();
      result = '上次检测：会话有效';
    } on SessionExpiredException {
      result = '会话已失效，请重新登录';
    } catch (_) {
      result = '暂时无法确认会话状态，请检查网络或稍后重试';
    }
    if (!mounted ||
        generation != _generation ||
        widget.currentSession() != session) {
      return;
    }
    setState(() {
      _checking = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.session == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_checking) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          const Text('正在检测会话…'),
        ] else if (_result != null)
          Text(_result!),
        TextButton.icon(
          onPressed: _checking || !widget.enabled
              ? null
              : () {
                  if (!_checking && widget.enabled) _check();
                },
          icon: const Icon(Icons.refresh),
          label: const Text('检测会话'),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
