import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'data/library.dart';
import 'data/session.dart';
import 'sources/sfacg_source.dart';
import 'ui/home.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final cipher = Map<String, String>.from(
      jsonDecode(await rootBundle.loadString('assets/sfacg_cipher.json')),
    );
    final api = await SfacgSession.open();
    final library = await Library.open(SfacgSource(api, cipher: cipher));
    runApp(UnrApp(library: library));
  } catch (e) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: SelectableText('启动失败，现有书库未被修改。\n$e'),
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
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff52745c),
          brightness: library.night ? Brightness.dark : Brightness.light,
        ),
        scaffoldBackgroundColor: library.night
            ? const Color(0xff161c19)
            : const Color(0xfff6f5ef),
        appBarTheme: const AppBarTheme(centerTitle: false),
      ),
      home: HomePage(library: library),
    ),
  );
}
