// App theme — dark, professional cinema-monitor look.
// Background #111111, accent orange #FF6D00, secondary translucent white/cyan/red.
library;

import 'package:flutter/material.dart';

class AppColors {
  static const Color background = Color(0xFF111111);
  static const Color surface = Color(0xFF1C1C1E);
  static const Color surfaceVariant = Color(0xFF2C2C2E);
  static const Color accent = Color(0xFFFF6D00);
  static const Color accentDim = Color(0xFFB04B00);
  static const Color onAccent = Color(0xFF000000);
  static const Color onSurface = Color(0xFFEDEDED);
  static const Color onSurfaceMuted = Color(0xFF9A9A9E);
  static const Color cyan = Color(0xFF00E5FF);
  static const Color red = Color(0xFFFF3B30);
  static const Color green = Color(0xFF34C759);
  static const Color yellow = Color(0xFFFFCC00);
  static const Color overlayWhite = Color(0xCCFFFFFF);
}

class AppTheme {
  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      colorScheme: const ColorScheme.dark(
        surface: AppColors.background,
        primary: AppColors.accent,
        secondary: AppColors.cyan,
        error: AppColors.red,
        onSurface: AppColors.onSurface,
      ),
      scaffoldBackgroundColor: AppColors.background,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.onSurface,
        elevation: 0,
        centerTitle: false,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.selected)) return AppColors.accent;
          return AppColors.onSurfaceMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.selected)) return AppColors.accentDim;
          return AppColors.surfaceVariant;
        }),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: AppColors.accent,
        inactiveTrackColor: AppColors.surfaceVariant,
        thumbColor: AppColors.accent,
        overlayColor: Color(0x33FF6D00),
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: AppColors.surfaceVariant,
        selectedColor: AppColors.accent,
        labelStyle: TextStyle(color: AppColors.onSurface),
      ),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: AppColors.onSurface),
        bodyMedium: TextStyle(color: AppColors.onSurface),
        bodySmall: TextStyle(color: AppColors.onSurfaceMuted),
        titleLarge: TextStyle(color: AppColors.onSurface, fontWeight: FontWeight.w600),
        labelLarge: TextStyle(color: AppColors.onSurface),
      ),
      iconTheme: const IconThemeData(color: AppColors.onSurface),
    );
  }
}
