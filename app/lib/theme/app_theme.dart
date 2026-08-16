import 'package:flutter/material.dart';

/// Central visual design constants for Medical Engineer Assistant.
///
/// Calm, low-contrast palette: warm cream background, muted tan borders,
/// warm charcoal text. The one accent — medical blue — is used sparingly,
/// only for: the app title, the send button, the active tab indicator, and
/// a soft tint behind the user's own messages. Everything else (icons,
/// dividers, chips, badges) stays neutral.
class AppColors {
  AppColors._();

  static const Color medicalBlue = Color(0xFF2C5F8A);
  static const Color background = Color(0xFFF5F4ED);
  static const Color surface = Color(0xFFFAF9F5);
  static const Color border = Color(0xFFDEDACC);
  static const Color text = Color(0xFF2D2A26);

  static const Color agentBubble = surface;
  static const Color agentBubbleBorder = border;
  static const Color userBubbleBackground = Color(0xFFE4ECF2); // soft blue tint
  static const Color userBubbleBorder = border;
  static const Color bubbleText = text;
  static const Color titleText = medicalBlue;
  static const Color divider = border;

  /// Neutral icon/utility tone — everything that isn't one of the four
  /// sparing accent uses above (attach button, history/new-chat icons,
  /// file-type icons, badges, chip borders, ...).
  static const Color neutralIcon = Color(0xFF6B665C);
  static Color mutedText(double opacity) => text.withValues(alpha: opacity);
}

/// Structural chrome (dividers, input outline, chip borders) — unchanged
/// from the original "slightly thicker than default" spec.
const double kBorderWidth = 2.5;

/// Thinner border reserved for message bubbles specifically, for a calmer
/// look than the app's structural chrome.
const double kBubbleBorderWidth = 1.2;

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.medicalBlue,
      brightness: Brightness.light,
      primary: AppColors.medicalBlue,
      surface: AppColors.surface,
    ),
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: 'Roboto',
  );

  final withTextTheme = base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: AppColors.text, displayColor: AppColors.text),
  );

  return withTextTheme.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: AppColors.background,
      elevation: 0,
      titleTextStyle: const TextStyle(
        color: AppColors.titleText,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
      iconTheme: const IconThemeData(color: AppColors.neutralIcon),
      shape: const Border(
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
      indicatorColor: AppColors.medicalBlue.withValues(alpha: 0.14),
      surfaceTintColor: AppColors.background,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          color: selected ? AppColors.medicalBlue : AppColors.mutedText(0.55),
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          fontSize: 12,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? AppColors.medicalBlue : AppColors.mutedText(0.55),
        );
      }),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: AppColors.border, width: kBorderWidth),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: AppColors.border, width: kBorderWidth),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: const BorderSide(color: AppColors.medicalBlue, width: kBorderWidth),
      ),
    ),
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.medicalBlue,
      surface: AppColors.surface,
    ),
  );
}
