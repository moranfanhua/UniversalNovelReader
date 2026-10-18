import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_verification.dart';
import 'package:unr/sources/source_verification.dart';
import 'package:unr/ui/source_sms_verification.dart';
import 'package:unr/ui/source_verification.dart';

Future<T?> solveCaptcha<T>(SourceVerificationChallenge<T> challenge) async =>
    challenge.parseResult({'ret': 0, 'ticket': 'ticket', 'randstr': 'random'});

SfacgSmsVerificationChallenge challenge({
  required Future<void> Function(SfacgVerificationResult) send,
  required Future<void> Function(String) submit,
  DateTime? expiresAt,
}) => SfacgSmsVerificationChallenge(
  maskedDestination: '+86 ****0000',
  expiresAt: expiresAt ?? DateTime.now().add(const Duration(minutes: 15)),
  loadCaptcha: () async => SfacgVerificationChallenge(
    aid: 'aid',
    expiresAt: DateTime.now().add(const Duration(minutes: 5)),
  ),
  send: send,
  submit: submit,
  checkActive: () {},
);

Future<void> open(
  WidgetTester tester,
  SfacgSmsVerificationChallenge challenge, {
  SourceVerificationSolver? solver,
  ValueChanged<bool?>? onResult,
  bool dispatch = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final result = dispatch
                  ? await SourceVerificationPage.solve(context, challenge)
                  : await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => SourceSmsVerificationPage(
                          challenge: challenge,
                          verificationSolver: solver ?? solveCaptcha,
                        ),
                      ),
                    );
              challenge.close();
              onResult?.call(result);
            },
            child: const Text('打开验证'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开验证'));
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [320.0, 1280.0]) {
    testWidgets('短信页支持错码重试和倒计时，宽度 $width 与两倍文字', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var sends = 0, submits = 0;
      bool? result;
      final sms = challenge(
        send: (_) async => sends++,
        submit: (code) async {
          submits++;
          if (code != '001234') throw const SourceException('验证码不正确，请重新输入');
        },
      );
      await open(tester, sms, onResult: (value) => result = value);
      expect(find.text('接收手机号：+86 ****0000'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('获取短信验证码'));
      await tester.pumpAndSettle();
      expect(sends, 1);
      expect(find.textContaining('秒后重新获取'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), '000000');
      await tester.pump();
      await tester.ensureVisible(find.text('提交验证码'));
      await tester.tap(find.text('提交验证码'));
      await tester.pumpAndSettle();
      expect(find.text('验证码不正确，请重新输入'), findsOneWidget);
      expect(submits, 1);
      expect(result, isNull);
      await tester.enterText(find.byType(TextField), '001234');
      await tester.pump();
      await tester.ensureVisible(find.text('提交验证码'));
      await tester.tap(find.text('提交验证码'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(sends, 1);
      expect(submits, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('共用入口分派至短信表单，取消不触发发码或提交', (tester) async {
    var writes = 0;
    final sms = challenge(
      send: (_) async => writes++,
      submit: (_) async => writes++,
    );
    await open(tester, sms, dispatch: true);
    expect(find.text('菠萝包短信安全验证'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('打开验证'), findsOneWidget);
    expect(writes, 0);
  });

  testWidgets('短信页面退出后，迟到的人机回调不会发送短信', (tester) async {
    final release = Completer<void>();
    var writes = 0;
    final sms = challenge(
      send: (_) async => writes++,
      submit: (_) async => writes++,
    );
    await open(
      tester,
      sms,
      solver: <T>(challenge) async {
        await release.future;
        return solveCaptcha(challenge);
      },
    );
    await tester.tap(find.text('获取短信验证码'));
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    release.complete();
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.text('打开验证'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('验证过期显示明确提示并禁用输入、发码和提交', (tester) async {
    final sms = challenge(
      send: (_) async => fail('过期不能发码'),
      submit: (_) async => fail('过期不能提交'),
      expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    await open(tester, sms);
    expect(find.text('本次短信验证已过期，请返回后重新发起验证'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
