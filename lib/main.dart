import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'data/library.dart';
import 'data/app_log.dart';
import 'data/error_logging.dart';
import 'sources/sfacg/sfacg_session.dart';
import 'sources/sfacg/sfacg_source.dart';
import 'sources/fanqie/fanqie_source.dart';
import 'sources/fanqie/fanqie_session.dart';
import 'ui/home.dart';
import 'ui/logs.dart';
import 'ui/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final log = AppLog.instance;
  installErrorLogging(log);
  await log.initialize();
  log.record(LogLevel.info, 'app.starting');
  try {
    final cipher = Map<String, String>.from(
      jsonDecode(await rootBundle.loadString('assets/sfacg_cipher.json')),
    );
    final api = await SfacgSession.open();
    final fanqieCipher = Map<String, String>.from(
      jsonDecode(await rootBundle.loadString('assets/fanqie_cipher.json')),
    );
    final fanqieApi = await FanqieSession.open();
    final library = await Library.open(
      SfacgSource(api, cipher: cipher),
      novelSources: [FanqieSource(fanqieApi, cipher: fanqieCipher)],
    );
    log.record(LogLevel.info, 'app.started');
    runApp(UnrApp(library: library));
  } catch (e, stack) {
    log.record(LogLevel.error, 'app.start_failed', error: e, stackTrace: stack);
    runApp(
      MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        builder: AppTheme.wrapSystemUi,
        home: Scaffold(
          appBar: AppBar(title: const Text('启动失败')),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText('启动失败，现有书库未被修改。\n$e'),
                  const SizedBox(height: 16),
                  Builder(
                    builder: (context) => FilledButton(
                      onPressed: () => Navigator.push<void>(
                        context,
                        MaterialPageRoute(builder: (_) => const LogsPage()),
                      ),
                      child: const Text('查看或导出日志'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class UnrApp extends StatelessWidget {
  const UnrApp({super.key, required this.library});
  final Library library;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: library,
    builder: (context, _) => MaterialApp(
      title: 'UNR 阅读器',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: switch (library.themeMode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      },
      builder: AppTheme.wrapSystemUi,
      home: HomePage(library: library),
    ),
  );
}
