import 'package:flutter/material.dart';

class TanukiColors {
  static const background = Color(0xFF081018);
  static const backgroundAlt = Color(0xFF0D1620);
  static const panel = Color(0xA60A0E14);
  static const panelEnd = Color(0xC010141B);
  static const panelSolid = Color(0xFF132132);
  static const panelStroke = Color(0xFF334A62);
  static const rail = Color(0xFF090C11);
  static const orange = Color(0xFFF47521);
  static const orangeHot = Color(0xFFFF9A3D);
  static const amber = Color(0xFFF4D46B);
  static const cyan = Color(0xFF67D8FF);
  static const text = Color(0xFFFFFFFF);
  static const muted = Color(0xFFA7BACB);
  static const subtle = Color(0xFF7E91A4);
  static const danger = Color(0xFFFF6B6B);
}

final tanukiTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: TanukiColors.background,
  colorScheme: const ColorScheme.dark(
    primary: TanukiColors.orange,
    secondary: TanukiColors.cyan,
    surface: TanukiColors.panelSolid,
  ),
  fontFamily: 'Roboto',
  textTheme: const TextTheme(
    headlineLarge: TextStyle(
        fontSize: 34, fontWeight: FontWeight.w800, color: TanukiColors.text),
    headlineMedium: TextStyle(
        fontSize: 28, fontWeight: FontWeight.w800, color: TanukiColors.text),
    titleLarge: TextStyle(
        fontSize: 22, fontWeight: FontWeight.w800, color: TanukiColors.text),
    titleMedium: TextStyle(
        fontSize: 17, fontWeight: FontWeight.w700, color: TanukiColors.text),
    bodyLarge: TextStyle(fontSize: 15, color: TanukiColors.text),
    bodyMedium: TextStyle(fontSize: 14, color: TanukiColors.muted),
    labelLarge: TextStyle(
        fontSize: 13, fontWeight: FontWeight.w800, color: TanukiColors.text),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: TanukiColors.orange,
      foregroundColor: Colors.black,
      minimumSize: const Size(44, 44),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(fontWeight: FontWeight.w800),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: TanukiColors.text,
      minimumSize: const Size(44, 44),
      side: const BorderSide(color: TanukiColors.panelStroke),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(fontWeight: FontWeight.w800),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: TanukiColors.panel,
    hintStyle: const TextStyle(color: Color(0xFF88A2B7)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    enabledBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: Color(0x44334A62)),
      borderRadius: BorderRadius.circular(8),
    ),
    focusedBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: TanukiColors.cyan),
      borderRadius: BorderRadius.circular(8),
    ),
  ),
);

BoxDecoration glassDecoration({
  Color color = TanukiColors.panel,
  Color borderColor = TanukiColors.panelStroke,
  double radius = 14,
}) {
  final useGlassGradient = color == TanukiColors.panel;
  return BoxDecoration(
    color: useGlassGradient ? null : color,
    gradient: useGlassGradient
        ? const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [TanukiColors.panel, TanukiColors.panelEnd],
          )
        : null,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: borderColor.withValues(alpha: 0.55)),
    boxShadow: const [
      BoxShadow(
        color: Color(0x55000000),
        blurRadius: 16,
        offset: Offset(0, 8),
      ),
    ],
  );
}
