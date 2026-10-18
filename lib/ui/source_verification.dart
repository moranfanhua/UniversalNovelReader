import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import '../sources/source_verification.dart';

class SourceVerificationPage<T> extends StatefulWidget {
  const SourceVerificationPage({super.key, required this.challenge});

  final SourceVerificationChallenge<T> challenge;

  static Future<T?> solve<T>(
    BuildContext context,
    SourceVerificationChallenge<T> challenge,
  ) => Navigator.of(context).push<T>(
    MaterialPageRoute(
      builder: (_) => SourceVerificationPage<T>(challenge: challenge),
    ),
  );

  @override
  State<SourceVerificationPage<T>> createState() =>
      _SourceVerificationPageState<T>();
}

class _SourceVerificationPageState<T> extends State<SourceVerificationPage<T>> {
  WebViewEnvironment? _environment;
  late SourceVerificationDocument _document;
  Timer? _loadTimer, _expiryTimer;
  bool _prepared = false, _loading = true, _completed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Plugin debug events include JS arguments; never log captcha tickets.
    PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
    _document = widget.challenge.createDocument(const Uuid().v4());
    if (!widget.challenge.expiresAt.isAfter(DateTime.now())) {
      _error = '本次安全验证已过期，请返回后重新发起验证';
      _loading = false;
      return;
    }
    _expiryTimer = Timer(
      widget.challenge.expiresAt.difference(DateTime.now()),
      () => _fail('本次安全验证已过期，请返回后重新发起验证'),
    );
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      if (kIsWeb ||
          (defaultTargetPlatform != TargetPlatform.android &&
              defaultTargetPlatform != TargetPlatform.windows)) {
        _fail('当前平台暂不支持${widget.challenge.title}');
        return;
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final version = await WebViewEnvironment.getAvailableVersion();
        if (!mounted) return;
        if (version == null || version.isEmpty) {
          _fail('未检测到 Microsoft Edge WebView2 运行时，请安装后重新验证');
          return;
        }
        final directory = await getApplicationSupportDirectory();
        final profile = Directory(
          '${directory.path}/${widget.challenge.profileId}_captcha_webview',
        );
        await profile.create(recursive: true);
        final environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: profile.path),
        );
        if (!mounted) {
          await environment.dispose();
          return;
        }
        _environment = environment;
      }
      if (!mounted || _error != null) return;
      setState(() => _prepared = true);
      _startLoadTimer();
    } catch (_) {
      _fail('无法启动安全验证，请检查系统 WebView 后重试');
    }
  }

  void _startLoadTimer() {
    _loadTimer?.cancel();
    _loadTimer = Timer(
      const Duration(seconds: 45),
      () => _fail('安全验证加载超时，请检查网络后重试'),
    );
  }

  void _fail(String message, {String? nonce}) {
    if (!mounted || _completed || (nonce != null && nonce != _document.nonce)) {
      return;
    }
    _loadTimer?.cancel();
    setState(() {
      _error = message;
      _loading = false;
    });
  }

  void _retry() {
    if (!widget.challenge.expiresAt.isAfter(DateTime.now())) return;
    setState(() {
      _error = null;
      _loading = true;
      _document = widget.challenge.createDocument(const Uuid().v4());
    });
    if (_prepared) {
      _startLoadTimer();
    } else {
      _prepare();
    }
  }

  void _callback(List<dynamic> arguments, String nonce) {
    if (!mounted ||
        _completed ||
        ModalRoute.of(context)?.isCurrent != true ||
        _error != null ||
        nonce != _document.nonce ||
        arguments.length != 3 ||
        arguments[0] != nonce) {
      return;
    }
    if (!widget.challenge.expiresAt.isAfter(DateTime.now())) {
      _fail('本次安全验证已过期，请返回后重新发起验证');
      return;
    }
    switch (arguments[1]) {
      case 'ready':
        _loadTimer?.cancel();
        setState(() => _loading = false);
      case 'error':
        _fail('安全验证加载失败，请检查网络后重试');
      case 'result':
        try {
          final result = widget.challenge.parseResult(arguments[2]);
          _completed = true;
          Navigator.of(context).pop(result);
        } on SourceException catch (error) {
          _fail(error.message);
        }
    }
  }

  Widget _webView() {
    final document = _document;
    return InAppWebView(
      key: ValueKey(document.nonce),
      webViewEnvironment: _environment,
      initialUrlRequest: URLRequest(url: WebUri.uri(document.uri)),
      initialSettings: InAppWebViewSettings(
        useShouldInterceptRequest: true,
        useShouldOverrideUrlLoading: true,
        javaScriptEnabled: true,
        domStorageEnabled: true,
        supportMultipleWindows: false,
        javaScriptCanOpenWindowsAutomatically: false,
        allowFileAccess: false,
        allowContentAccess: false,
        isInspectable: false,
        javaScriptHandlersForMainFrameOnly: true,
        javaScriptHandlersOriginAllowList: {document.uri.origin},
      ),
      onWebViewCreated: (controller) => controller.addJavaScriptHandler(
        handlerName: document.handlerName,
        callback: (JavaScriptHandlerFunctionData data) {
          if (data.isMainFrame &&
              data.origin.toString() == document.uri.origin &&
              data.requestUrl.toString() == document.uri.toString()) {
            _callback(data.args, document.nonce);
          }
        },
      ),
      shouldInterceptRequest: (_, request) async {
        if (request.url.toString() != document.uri.toString()) return null;
        return WebResourceResponse(
          contentType: 'text/html',
          contentEncoding: 'utf-8',
          data: Uint8List.fromList(utf8.encode(document.html)),
          statusCode: 200,
          reasonPhrase: 'OK',
          headers: {'Cache-Control': 'no-store'},
        );
      },
      shouldOverrideUrlLoading: (_, action) async {
        if (action.isForMainFrame &&
            action.request.url?.toString() != document.uri.toString()) {
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      },
      onCreateWindow: (_, _) async => false,
      onPermissionRequest: (_, request) async => PermissionResponse(
        resources: request.resources,
        action: PermissionResponseAction.DENY,
      ),
      onReceivedError: (_, request, _) {
        if (request.isForMainFrame == true) {
          _fail('安全验证页面加载失败，请检查网络后重试', nonce: document.nonce);
        }
      },
      onReceivedHttpError: (_, request, _) {
        if (request.isForMainFrame == true) {
          _fail('安全验证服务暂时不可用，请稍后重试', nonce: document.nonce);
        }
      },
    );
  }

  @override
  void dispose() {
    _completed = true;
    _loadTimer?.cancel();
    _expiryTimer?.cancel();
    unawaited(_environment?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.challenge.title)),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(widget.challenge.instruction),
              ),
              if (_loading) const LinearProgressIndicator(),
              Expanded(
                child: _error != null
                    ? Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!),
                              const SizedBox(height: 16),
                              if (widget.challenge.expiresAt.isAfter(
                                DateTime.now(),
                              ))
                                FilledButton(
                                  onPressed: _retry,
                                  child: const Text('重新加载验证'),
                                ),
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: Text(widget.challenge.returnLabel),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _prepared
                    ? _webView()
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
