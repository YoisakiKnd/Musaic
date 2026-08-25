import 'package:flutter/material.dart';

/// Musaic 设计令牌（Design Tokens）
///
/// 深色优先，Apple Music 风格。
class AppTokens {
  AppTokens._();

  // ── 品牌色 ──────────────────────────────────────────────
  static const Color brandRed = Color(0xFFFA2D48);
  static const Color brandPink = Color(0xFFFB266B);
  static const Color brandOrange = Color(0xFFFF6B35);

  static const LinearGradient brandGradient = LinearGradient(
    colors: [brandRed, brandPink, brandOrange],
    stops: [0.0, 0.5, 1.0],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient brandGradientVertical = LinearGradient(
    colors: [brandRed, brandPink],
    stops: [0.0, 1.0],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // ── 背景 / 表面 ─────────────────────────────────────────
  static const Color surfaceBase = Color(0xFF0A0A0F);
  static const Color surface = Color(0xFF14141F);
  static const Color surfaceSecondary = Color(0xFF1E1E2E);
  static const Color surfaceTertiary = Color(0xFF2A2A3C);

  // ── 文本 ─────────────────────────────────────────────────
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFB8B8C8);
  static const Color textTertiary = Color(0xFF6E6E7E);

  // ── 功能色 ──────────────────────────────────────────────
  static const Color success = Color(0xFF34C759);
  static const Color warning = Color(0xFFFF9500);
  static const Color error = Color(0xFFFF3B30);

  // ── 圆角 ────────────────────────────────────────────────
  static const double radiusLarge = 24.0;
  static const double radiusXLarge = 28.0;
  static const double radiusMedium = 16.0;
  static const double radiusSmall = 12.0;

  static BorderRadius get borderRadiusLarge => BorderRadius.circular(radiusLarge);
  static BorderRadius get borderRadiusXLarge => BorderRadius.circular(radiusXLarge);
  static BorderRadius get borderRadiusMedium => BorderRadius.circular(radiusMedium);
  static BorderRadius get borderRadiusSmall => BorderRadius.circular(radiusSmall);

  // ── 模糊 ────────────────────────────────────────────────
  static const double blurSigmaLight = 12.0;
  static const double blurSigmaHeavy = 24.0;

  // ── 动效 ────────────────────────────────────────────────
  static const Duration durationFast = Duration(milliseconds: 200);
  static const Duration durationNormal = Duration(milliseconds: 350);
  static const Duration durationSlow = Duration(milliseconds: 450);
  static const Duration durationSlower = Duration(milliseconds: 600);

  static const Curve curveEmphasized = Curves.easeInOutCubicEmphasized;
  static const Curve curveDecelerate = Curves.easeOutCubic;
  static const Curve curveAccelerate = Curves.easeInCubic;

  // ── 阴影 / 玻璃 ────────────────────────────────────────
  static List<BoxShadow> get glassShadow => const [
    BoxShadow(
      color: Color(0x1A000000),
      blurRadius: 24,
      offset: Offset(0, 8),
    ),
  ];

  static Color glassColor({double alpha = 0.72}) =>
      Color.alphaBlend(textPrimary.withValues(alpha: 0.08), surface).withValues(alpha: alpha);

  // ── 尺寸 ────────────────────────────────────────────────
  static const double miniPlayerHeight = 64.0;
  static const double bottomNavHeight = 80.0;
  static const double railWidth = 72.0;
  static const double maxContentWidth = 840.0;

  // ── 主题数据 ────────────────────────────────────────────
  static ThemeData get darkTheme {
    final base = ThemeData.dark(useMaterial3: true);
    final defaultScheme = base.colorScheme;
    final colorScheme = defaultScheme.copyWith(
      primary: brandRed,
      onPrimary: Colors.white,
      secondary: brandPink,
      tertiary: brandOrange,
      surface: surface,
      error: error,
    );

    return base.copyWith(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: surfaceBase,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: surface,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          color: textPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: base.cardTheme.copyWith(
        color: surfaceSecondary,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: borderRadiusMedium,
        ),
      ),
      dividerTheme: base.dividerTheme.copyWith(
        color: surfaceTertiary,
        thickness: 0.5,
        space: 1,
      ),
      textTheme: base.textTheme.copyWith(
        displayLarge: const TextStyle(color: textPrimary),
        displayMedium: const TextStyle(color: textPrimary),
        displaySmall: const TextStyle(color: textPrimary),
        headlineLarge: const TextStyle(color: textPrimary),
        headlineMedium: const TextStyle(color: textPrimary),
        headlineSmall: const TextStyle(color: textPrimary),
        titleLarge: const TextStyle(color: textPrimary),
        titleMedium: const TextStyle(color: textPrimary),
        titleSmall: const TextStyle(color: textPrimary),
        bodyLarge: const TextStyle(color: textPrimary),
        bodyMedium: const TextStyle(color: textSecondary),
        bodySmall: const TextStyle(color: textTertiary),
        labelLarge: const TextStyle(color: textPrimary),
        labelMedium: const TextStyle(color: textSecondary),
        labelSmall: const TextStyle(color: textTertiary),
      ),
      iconTheme: base.iconTheme.copyWith(color: textSecondary),
    );
  }

  static ThemeData get lightTheme {
    final base = ThemeData.light(useMaterial3: true);
    final colorScheme = base.colorScheme.copyWith(
      primary: brandRed,
      onPrimary: Colors.white,
      secondary: brandPink,
      tertiary: brandOrange,
      surface: const Color(0xFFF2F2F7),
      onSurface: const Color(0xFF1C1C1E),
      error: error,
    );

    return base.copyWith(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: const Color(0xFFFFFFFF),
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: const Color(0xFFF2F2F7),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          color: const Color(0xFF1C1C1E),
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: base.cardTheme.copyWith(
        color: const Color(0xFFF9F9FC),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: borderRadiusMedium,
        ),
      ),
      dividerTheme: base.dividerTheme.copyWith(
        color: surfaceTertiary,
        thickness: 0.5,
        space: 1,
      ),
    );
  }
}
