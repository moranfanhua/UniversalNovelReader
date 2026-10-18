import 'dart:async';

import 'package:flutter/material.dart';

import '../data/library.dart';
import '../sources/saved_session_check.dart';
import 'account.dart';

/// Run after the first frame, once per app launch, without delaying the shelf
/// or cached reading. Theme changes and returning to the app do not repeat it.
class StartupSessionCheck extends StatefulWidget {
  const StartupSessionCheck({
    super.key,
    required this.library,
    required this.child,
  });

  final Library library;
  final Widget child;

  @override
  State<StartupSessionCheck> createState() => _StartupSessionCheckState();
}

class _StartupSessionCheckState extends State<StartupSessionCheck> {
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scheduleCheck();
  }

  @override
  void didUpdateWidget(StartupSessionCheck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) _scheduleCheck();
  }

  void _scheduleCheck() {
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _generation) {
        unawaited(_check(generation));
      }
    });
  }

  Future<void> _check(int generation) async {
    final library = widget.library;
    final results = await checkSavedSessions(library.searchSources);
    if (!mounted || generation != _generation) return;
    final expired = results
        .where((result) => result.isCurrent)
        .map((result) => result.sourceName)
        .join('、');
    if (expired.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$expired登录会话已失效，请重新登录。已缓存章节仍可阅读。'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: '账号设置',
          onPressed: () {
            if (!mounted || generation != _generation) return;
            Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => AccountSettingsPage(library: library),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
