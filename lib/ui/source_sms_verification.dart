import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sources/source_verification.dart';
import 'source_verification.dart';

class SourceSmsVerificationPage extends StatefulWidget {
  const SourceSmsVerificationPage({
    super.key,
    required this.challenge,
    this.verificationSolver,
  });

  final SourceSmsVerificationChallenge challenge;
  final SourceVerificationSolver? verificationSolver;

  @override
  State<SourceSmsVerificationPage> createState() =>
      _SourceSmsVerificationPageState();
}

class _SourceSmsVerificationPageState extends State<SourceSmsVerificationPage> {
  final _code = TextEditingController();
  Timer? _timer;
  bool _busy = false;
  String? _message;

  bool get _expired => !widget.challenge.expiresAt.isAfter(DateTime.now());
  bool get _active => mounted && ModalRoute.of(context)?.isCurrent == true;
  int get _remaining =>
      ((widget.challenge.resendAt?.difference(DateTime.now()).inMilliseconds ??
                  0) /
              1000)
          .ceil()
          .clamp(0, 60);

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || _expired || _remaining > 0) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final sent = await widget.challenge.sendCode(<T>(challenge) async {
        if (!_active || _expired) return null;
        final result = widget.verificationSolver != null
            ? await widget.verificationSolver!(challenge)
            : await SourceVerificationPage.solve(context, challenge);
        return _active && !_expired ? result : null;
      });
      if (_active) {
        setState(() {
          _message = sent ? '验证码已发送，请查看短信' : '已取消人机验证，可重新获取验证码';
        });
      }
    } catch (error) {
      if (_active) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_busy || _expired) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.challenge.submitCode(_code.text);
      if (!mounted) return;
      if (_active) Navigator.of(context).pop(true);
    } catch (error) {
      if (_active) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.challenge.title)),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(widget.challenge.instruction),
              const SizedBox(height: 16),
              Text('接收手机号：${widget.challenge.maskedDestination}'),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: _busy || _expired || _remaining > 0 ? null : _send,
                child: Text(_remaining > 0 ? '$_remaining 秒后重新获取' : '获取短信验证码'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _code,
                enabled: !_busy && !_expired,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                autofillHints: const [AutofillHints.oneTimeCode],
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: '短信验证码',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed:
                    _busy ||
                        _expired ||
                        !widget.challenge.canSubmit ||
                        _code.text.trim().isEmpty
                    ? null
                    : _submit,
                child: const Text('提交验证码'),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_expired || _message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(_expired ? '本次短信验证已过期，请返回后重新发起验证' : _message!),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
