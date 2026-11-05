import 'package:flutter/material.dart';

import '../sources/source_verification.dart';
import 'source_verification.dart';

/// Account pages can opt in without knowing a source's verification protocol.
class SourceVerificationButton extends StatefulWidget {
  const SourceVerificationButton({
    super.key,
    required this.source,
    this.enabled = true,
    this.solver,
    this.onBusyChanged,
    this.retryHint = '可返回原页面重试。',
  });

  final VerifiableNovelSource source;
  final bool enabled;
  final SourceVerificationSolver? solver;
  final ValueChanged<bool>? onBusyChanged;
  final String retryHint;

  @override
  State<SourceVerificationButton> createState() =>
      _SourceVerificationButtonState();
}

class _SourceVerificationButtonState extends State<SourceVerificationButton> {
  bool _busy = false;
  String? _message;

  Future<void> _verify() async {
    if (_busy || !widget.enabled || !widget.source.canVerifyAccess) return;
    final source = widget.source;
    setState(() {
      _busy = true;
      _message = null;
    });
    widget.onBusyChanged?.call(true);
    try {
      final outcome = await source.verifyAccess(<T>(challenge) async {
        if (!mounted ||
            widget.source != source ||
            ModalRoute.of(context)?.isCurrent != true) {
          return null;
        }
        final solver = widget.solver;
        final result = solver != null
            ? await solver(challenge)
            : await SourceVerificationPage.solve(context, challenge);
        return mounted &&
                widget.source == source &&
                ModalRoute.of(context)?.isCurrent == true
            ? result
            : null;
      });
      if (!mounted || widget.source != source) return;
      setState(() {
        _message = switch (outcome) {
          SourceVerificationOutcome.notRequired =>
            '当前账号无需安全验证，${widget.retryHint}',
          SourceVerificationOutcome.verified => '安全验证已通过，${widget.retryHint}',
          SourceVerificationOutcome.cancelled => '已取消安全验证。',
        };
      });
    } catch (error) {
      if (mounted && widget.source == source) {
        setState(() => _message = '$error');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      OutlinedButton.icon(
        onPressed: widget.enabled && !_busy && widget.source.canVerifyAccess
            ? _verify
            : null,
        icon: const Icon(Icons.verified_user_outlined),
        label: const Text('处理安全验证'),
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_message != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(_message!),
        ),
    ],
  );
}
