import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTheme {
  static ThemeData light() => _theme(Brightness.light);
  static ThemeData dark() => _theme(Brightness.dark);

  static Color _background(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xff161c19)
      : const Color(0xfff6f5ef);

  static ThemeData _theme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff52745c),
      brightness: brightness,
    ),
    scaffoldBackgroundColor: _background(brightness),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      systemOverlayStyle: _systemUi(brightness),
    ),
  );

  static SystemUiOverlayStyle _systemUi(Brightness brightness) =>
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarBrightness: brightness,
        statusBarIconBrightness: brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarColor: _background(brightness),
        systemNavigationBarIconBrightness: brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
      );

  // Readers hide their app bar, so the route still needs a system bar style.
  static Widget wrapSystemUi(BuildContext context, Widget? child) =>
      AnnotatedRegion<SystemUiOverlayStyle>(
        value: _systemUi(Theme.of(context).brightness),
        child: child ?? const SizedBox.shrink(),
      );
}
