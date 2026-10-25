import 'package:flutter/material.dart';

class KColors {
  static const green = Color(0xFF285C4D);
  static const darkGreen = Color(0xFF153E32);
  static const lime = Color(0xFFDDF3B4);
  static const sage = Color(0xFFEDF3EB);
  static const canvas = Color(0xFFF7F8FA);
  static const ink = Color(0xFF202A2D);
  static const muted = Color(0xFF68756F);
  static const line = Color(0xFFE9ECEC);
  static const orange = Color(0xFFC9863A);
  static const red = Color(0xFFBA5A4B);
}

ThemeData kwadraTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: KColors.green,
    primary: KColors.green,
    surface: Colors.white,
    error: KColors.red,
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Manrope',
    colorScheme: scheme,
    scaffoldBackgroundColor: KColors.canvas,
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 32,
        height: 1.25,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.2,
        color: KColors.ink,
      ),
      headlineMedium: TextStyle(
        fontSize: 25,
        height: 1.3,
        fontWeight: FontWeight.w800,
        letterSpacing: -.7,
        color: KColors.ink,
      ),
      titleLarge: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w800,
        letterSpacing: -.4,
        color: KColors.ink,
      ),
      titleMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: KColors.ink,
      ),
      bodyLarge: TextStyle(fontSize: 14, height: 1.6, color: KColors.ink),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: KColors.ink),
      bodySmall: TextStyle(fontSize: 12, height: 1.5, color: KColors.muted),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    ),
    dividerTheme: const DividerThemeData(
      color: KColors.line,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: KColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: KColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: KColors.green, width: 1.5),
      ),
      hintStyle: const TextStyle(color: KColors.muted, fontSize: 14),
      labelStyle: const TextStyle(color: KColors.muted, fontSize: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: KColors.green,
        foregroundColor: Colors.white,
        elevation: 0,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        textStyle: const TextStyle(
          fontFamily: 'Manrope',
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: KColors.ink,
        backgroundColor: Colors.white,
        side: const BorderSide(color: KColors.line),
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        textStyle: const TextStyle(
          fontFamily: 'Manrope',
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: KColors.green,
        textStyle: const TextStyle(
          fontFamily: 'Manrope',
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: KColors.darkGreen,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 400),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
    ),
  );
}
