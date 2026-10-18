import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/qidian/qidian_captcha.dart';
import 'package:unr/ui/qidian_captcha.dart';
import 'package:unr/sources/sfacg/sfacg_verification.dart';
import 'package:unr/ui/source_verification.dart';

class _WebViewPlatform extends InAppWebViewPlatform {
  final views = <_WebView>[];

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = _WebView(params);
    views.add(view);
    return view;
  }
}

class _Controller extends PlatformInAppWebViewController {
  _Controller()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'test'),
      );
  final handlers = <String, Function>{};

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required Function callback,
  }) {
    handlers[handlerName] = callback;
  }
}

class _WebView extends PlatformInAppWebViewWidget {
  _WebView(super.params) : super.implementation();
  final controller = _Controller();
  bool _created = false;

  dynamic get publicController => controllerFromPlatform(controller);

  void result(
    String kind,
    Object? value, {
    String? nonce,
    bool mainFrame = true,
    String? origin,
  }) {
    final url = params.initialUrlRequest!.url!;
    controller.handlers.values.single(
      JavaScriptHandlerFunctionData(
        args: [nonce ?? url.pathSegments.last, kind, value],
        isMainFrame: mainFrame,
        origin: WebUri(origin ?? url.origin),
        requestUrl: url,
      ),
    );
  }

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      params.controllerFromPlatform!(controller) as T;

  @override
  Widget build(BuildContext context) {
    if (!_created) {
      _created = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        params.onWebViewCreated?.call(publicController);
      });
    }
    return const ColoredBox(color: Colors.white);
  }

  @override
  void dispose() {}
}

void main() {
  testWidgets('菠萝包复用验证容器，拒绝错误来源并只返回一次结果', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final platform = _WebViewPlatform();
    InAppWebViewPlatform.instance = platform;
    SfacgVerificationResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await SourceVerificationPage.solve(
              context,
              SfacgVerificationChallenge(
                aid: 'aid',
                expiresAt: DateTime.now().add(const Duration(minutes: 5)),
              ),
            ),
            child: const Text('打开验证'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开验证'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final view = platform.views.last;
    expect(view.controller.handlers.keys.single, 'sfacgVerification');
    expect(find.text('菠萝包安全验证'), findsOneWidget);
    final response = await view.params.shouldInterceptRequest!(
      view.publicController,
      WebResourceRequest(url: view.params.initialUrlRequest!.url!),
    );
    expect(response!.statusCode, 200);
    expect(
      view.params.initialUrlRequest!.headers ?? {},
      isNot(contains('Cookie')),
    );
    expect(view.params.initialSettings!.allowFileAccess, isFalse);
    expect(
      await view.params.shouldOverrideUrlLoading!(
        view.publicController,
        NavigationAction(
          request: URLRequest(url: WebUri('https://example.com')),
          isForMainFrame: true,
        ),
      ),
      NavigationActionPolicy.CANCEL,
    );
    final ticket = {'ret': 0, 'ticket': 'ticket', 'randstr': 'random'};
    view.result('result', ticket, origin: 'https://example.com');
    view.result('result', ticket, nonce: 'stale');
    view.result('result', ticket, mainFrame: false);
    await tester.pump();
    expect(result, isNull);
    view.result('ready', null);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    view.result('result', ticket);
    view.result('result', ticket);
    await tester.pumpAndSettle();
    expect(result!.ticket, 'ticket');
    expect(find.text('打开验证'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('已过期的验证不能接受结果或重试', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    InAppWebViewPlatform.instance = _WebViewPlatform();
    await tester.pumpWidget(
      MaterialApp(
        home: SourceVerificationPage(
          challenge: SfacgVerificationChallenge(
            aid: 'aid',
            expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('本次安全验证已过期，请返回后重新发起验证'), findsOneWidget);
    expect(find.text('重新加载验证'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  test('只接受验证成功且完整的腾讯票据；用户关闭验证返回取消', () {
    final result = QidianCaptchaResult.fromCallback({
      'ret': 0,
      'ticket': 'synthetic-ticket',
      'randstr': 'synthetic-random',
    });
    expect(result!.ticket, 'synthetic-ticket');
    expect(result.randstr, 'synthetic-random');
    expect(QidianCaptchaResult.fromCallback({'ret': 2}), isNull);
    for (final value in [
      null,
      'invalid',
      {},
      {'ret': 0},
      {'ret': '0', 'ticket': 'ticket', 'randstr': 'random'},
      {'ret': -1001, 'ticket': 'ticket', 'randstr': 'random'},
      {'ret': 0, 'ticket': '', 'randstr': 'random'},
      {'ret': 0, 'ticket': 'ticket\n', 'randstr': 'random'},
      {'ret': 0, 'ticket': 'ticket', 'randstr': 'random with spaces'},
      {'ret': 0, 'ticket': 123, 'randstr': 'random'},
    ]) {
      expect(
        () => QidianCaptchaResult.fromCallback(value),
        throwsA(isA<SourceException>()),
      );
    }
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets('验证启动失败可返回登录并适配宽度 $width 与两倍文字', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => QidianCaptchaPage.solve(
                context,
                QidianCaptchaChallenge(
                  expiresAt: DateTime.now().add(const Duration(minutes: 5)),
                ),
              ),
              child: const Text('打开验证'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开验证'));
      await tester.pumpAndSettle();
      expect(find.text('当前平台暂不支持起点安全验证'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('返回登录'));
      await tester.pumpAndSettle();
      expect(find.text('打开验证'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('本地包装页拦截、桥接来源校验与一次性成功回传', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final platform = _WebViewPlatform();
    InAppWebViewPlatform.instance = platform;
    QidianCaptchaResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await QidianCaptchaPage.solve(
              context,
              QidianCaptchaChallenge(
                expiresAt: DateTime.now().add(const Duration(minutes: 5)),
              ),
            ),
            child: const Text('打开验证'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开验证'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final view = platform.views.last;
    final response = await view.params.shouldInterceptRequest!(
      view.publicController,
      WebResourceRequest(url: view.params.initialUrlRequest!.url!),
    );
    expect(response!.statusCode, 200);
    expect(response.contentType, 'text/html');
    expect(
      await view.params.shouldInterceptRequest!(
        view.publicController,
        WebResourceRequest(
          url: WebUri('https://turing.captcha.qcloud.com/TCaptcha.js'),
        ),
      ),
      isNull,
    );
    final ticket = {
      'ret': 0,
      'ticket': 'synthetic-ticket',
      'randstr': 'synthetic-random',
    };
    view.result('result', ticket, nonce: 'wrong');
    view.result('result', ticket, mainFrame: false);
    view.result('result', ticket, origin: 'https://example.com');
    await tester.pump();
    expect(result, isNull);
    expect(find.text('起点安全验证'), findsOneWidget);
    view.result('ready', null);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    view.result('result', ticket);
    view.result('result', ticket);
    await tester.pumpAndSettle();
    expect(result!.ticket, 'synthetic-ticket');
    expect(find.text('打开验证'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('加载失败只重载验证页，旧页面回调失效，返回可取消', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final platform = _WebViewPlatform();
    InAppWebViewPlatform.instance = platform;
    await tester.pumpWidget(
      MaterialApp(
        home: QidianCaptchaPage(
          challenge: QidianCaptchaChallenge(
            expiresAt: DateTime.now().add(const Duration(minutes: 5)),
          ),
        ),
      ),
    );
    await tester.pump();
    final old = platform.views.last;
    old.result('error', null);
    await tester.pump();
    expect(find.text('安全验证加载失败，请检查网络后重试'), findsOneWidget);
    await tester.tap(find.text('重新加载验证'));
    await tester.pump();
    final current = platform.views.last;
    expect(
      current.params.initialUrlRequest!.url,
      isNot(old.params.initialUrlRequest!.url),
    );
    old.result('error', null);
    await tester.pump();
    expect(find.text('安全验证加载失败，请检查网络后重试'), findsNothing);
    current.result('ready', null);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('用户返回时迟到的验证结果不会关闭下层登录页', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final platform = _WebViewPlatform();
    InAppWebViewPlatform.instance = platform;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => TextButton(
                  onPressed: () => QidianCaptchaPage.solve(
                    context,
                    QidianCaptchaChallenge(
                      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
                    ),
                  ),
                  child: const Text('登录页'),
                ),
              ),
            ),
            child: const Text('主页'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('主页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登录页'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final view = platform.views.last;
    navigator.currentState!.pop();
    view.result('result', {'ret': 0, 'ticket': 'ticket', 'randstr': 'random'});
    await tester.pumpAndSettle();
    expect(find.text('登录页'), findsOneWidget);
    expect(find.text('主页'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
