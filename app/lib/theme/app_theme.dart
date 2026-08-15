import 'package:flutter/material.dart';

/// Central visual design constants for Medical Engineer Assistant.
///
/// Design brief: white background throughout, Facebook-blue accents,
/// borders a bit thicker than default, clean/functional over decorative.
class AppColors {
  AppColors._();

  static const Color facebookBlue = Color(0xFF1877F2);
  static const Color background = Colors.white;
  static const Color agentBubble = facebookBlue;
  static const Color userBubbleBackground = Color(0xFFF0F2F5);
  static const Color userBubbleBorder = facebookBlue;
  static const Color bubbleText = Colors.black;
  static const Color titleText = Colors.black;
  static const Color divider = facebookBlue;
}

/// Slightly thicker than a typical hairline divider (per design brief).
const double kBorderWidth = 2.5;

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.facebookBlue,
      brightness: Brightness.light,
      surface: AppColors.background,
    ),
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: 'Roboto',
  );

  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: AppColors.background,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: AppColors.titleText,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
      iconTheme: IconThemeData(color: AppColors.titleText),
      shape: Border(
        bottom: BorderSide(color: AppColors.divider, width: kBorderWidth),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.divider,
      thickness: kBorderWidth,
      space: kBorderWidth,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.background,
      indicatorColor: AppColors.facebookBlue.withValues(alpha: 0.12),
      surfaceTintColor: AppColors.background,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          color: selected ? AppColors.facebookBlue : Colors.black54,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          fontSize: 12,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? AppColors.facebookBlue : Colors.black54,
        );
      }),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.userBubbleBackground,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: AppColors.facebookBlue, width: kBorderWidth),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: AppColors.facebookBlue, width: kBorderWidth),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: AppColors.facebookBlue, width: kBorderWidth),
      ),
    ),
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.facebookBlue,
      surface: AppColors.background,
    ),
  );
}
