import 'package:flutter/material.dart';

/// Musaic 设计令牌（Master Plan §8）。
///
/// Apple Music 红渐变、24/28 圆角、受控模糊、动效曲线；深色优先。
/// 所有 UI 组件只允许引用此处令牌，禁止散落魔法数。
abstract final class AppTokens {
  // ---------- 品牌色 ----------
  /// 主品牌色（Apple Music 粉红，对齐 Mei）。
  static const Color accent = Color(0xFFFF2D55);

  /// 品牌渐变的深端。
  static const Color accentDeep = Color(0xFFE0173F);

  /// 品牌渐变。
  static const Gradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accent, accentDeep],
  );

  // ---------- 中性色（深色优先） ----------
  static const Color darkBackground = Color(0xFF151013);
  static const Color darkSurface = Color(0xFF1F181D);
  static const Color darkSurfaceHigh = Color(0xFF2B2127);
  static const Color darkOutline = Color(0xFF3B2F37);
  static const Color darkTextPrimary = Color(0xFFF2F2F7);
  static const Color darkTextSecondary = Color(0xFFA0A0AC);

  static const Color lightBackground = Color(0xFFF6F6F9);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceHigh = Color(0xFFEFEFF4);
  static const Color lightOutline = Color(0xFFDCDCE4);
  static const Color lightTextPrimary = Color(0xFF1B1B1F);
  static const Color lightTextSecondary = Color(0xFF66666F);

  // ---------- 几何 ----------
  static const double radiusCard = 24;
  static const double radiusSheet = 28;
  static const double radiusChip = 12;

  /// 自适应骨架断点：< 840 使用底部导航，>= 840 使用 NavigationRail。
  static const double compactBreakpoint = 840;

  static const EdgeInsets pagePadding = EdgeInsets.symmetric(
    horizontal: 20,
    vertical: 12,
  );

  // ---------- 动效 ----------
  static const Duration durationFast = Duration(milliseconds: 150);
  static const Duration durationNormal = Duration(milliseconds: 250);
  static const Duration durationSlow = Duration(milliseconds: 450);

  static const Curve curveEmphasized = Curves.easeOutCubic;

  // ---------- 性能预算（Master Plan §10.2） ----------
  /// 进度条刷新节流周期。
  static const Duration positionThrottle = Duration(milliseconds: 100);

  /// 每屏最多一个实时模糊区；其余场景使用静态模糊图。
  static const bool enableLiveBlurByDefault = true;

  // ---------- 主题 ----------
  static ThemeData get darkTheme => _buildTheme(Brightness.dark);

  static ThemeData get lightTheme => _buildTheme(Brightness.light);

  static ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      primary: accent,
      secondary: accent,
      surface: isDark ? darkSurface : lightSurface,
      onSurface: isDark ? darkTextPrimary : lightTextPrimary,
      surfaceContainerHighest: isDark ? darkSurfaceHigh : lightSurfaceHigh,
      outlineVariant: isDark ? darkOutline : lightOutline,
    );
    final textSecondary = isDark ? darkTextSecondary : lightTextSecondary;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          isDark ? darkBackground : lightBackground,
      splashFactory: InkRipple.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor:
            (isDark ? darkBackground : lightBackground).withValues(alpha: 0.92),
        indicatorColor: accent.withValues(alpha: 0.16),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? accent
                : textSecondary,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? accent
                : textSecondary,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor:
            (isDark ? darkBackground : lightBackground).withValues(alpha: 0.92),
        indicatorColor: accent.withValues(alpha: 0.16),
        selectedIconTheme: const IconThemeData(color: accent),
        selectedLabelTextStyle: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: accent,
        ),
        unselectedIconTheme: IconThemeData(color: textSecondary),
        unselectedLabelTextStyle: TextStyle(fontSize: 12, color: textSecondary),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: scheme.outlineVariant.withValues(alpha: 0.5),
        thumbColor: scheme.onSurface,
        overlayColor: accent.withValues(alpha: 0.12),
        trackHeight: 3,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? darkSurfaceHigh : darkTextPrimary,
        contentTextStyle: TextStyle(
          color: isDark ? darkTextPrimary : darkBackground,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusChip),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.5),
        thickness: 0.5,
      ),
    );
  }
}
