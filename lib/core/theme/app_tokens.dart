import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Musaic 设计令牌（Master Plan §8）。
///
/// 石墨灰中性色 + 品牌粉点缀、16/20 圆角、自适应断点与密度；深色优先。
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
  // 石墨灰而非偏粉的暗紫：品牌粉只出现在重点与选中态，
  // 此前底色、卡片、徽章全带粉调，整屏发闷且抢不出重点。
  static const Color darkBackground = Color(0xFF0F0F12);
  static const Color darkSurface = Color(0xFF18181C);
  static const Color darkSurfaceHigh = Color(0xFF232328);
  static const Color darkOutline = Color(0xFF2E2E35);
  static const Color darkTextPrimary = Color(0xFFF2F2F5);
  static const Color darkTextSecondary = Color(0xFF9B9BA4);

  static const Color lightBackground = Color(0xFFF7F7F8);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceHigh = Color(0xFFEEEEF1);
  static const Color lightOutline = Color(0xFFE0E0E6);
  static const Color lightTextPrimary = Color(0xFF17171A);
  static const Color lightTextSecondary = Color(0xFF6B6B73);

  // ---------- 几何 ----------
  static const double radiusCard = 16;
  static const double radiusSheet = 20;
  static const double radiusChip = 8;

  /// 封面圆角（列表缩略图 / 歌单卡 / 播放页大封面统一）。
  static const double radiusCover = 10;

  // ---------- 自适应断点（Material 3 窗口尺寸类） ----------
  /// < 600：手机竖屏——底部导航 + 悬浮迷你播放条。
  static const double mediumBreakpoint = 600;

  /// >= 1024：桌面 / 大平板——侧边栏 + 底部完整播放控制条。
  /// 600–1024 之间用导航栏轨（NavigationRail）。
  static const double expandedBreakpoint = 1024;

  /// 正文最大宽度：设置、表单类页面在宽屏上不拉满（行太长难读）。
  static const double readableMaxWidth = 760;

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

  // ---------- 主题 ----------
  static ThemeData get darkTheme => _buildTheme(Brightness.dark);

  /// OLED 纯黑深色主题：背景/卡片全部纯黑，省电且对比更强。
  static ThemeData get oledTheme => _buildTheme(Brightness.dark, oled: true);

  static ThemeData get lightTheme => _buildTheme(Brightness.light);

  static ThemeData _buildTheme(Brightness brightness, {bool oled = false}) {
    final isDark = brightness == Brightness.dark;
    final background =
        isDark ? (oled ? Colors.black : darkBackground) : lightBackground;
    final surface = isDark ? (oled ? Colors.black : darkSurface) : lightSurface;
    final surfaceHigh =
        isDark
            ? (oled ? const Color(0xFF141414) : darkSurfaceHigh)
            : lightSurfaceHigh;
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      primary: accent,
      secondary: accent,
      // primary 覆盖成品牌粉后必须同时指定 onPrimary：fromSeed 在深色模式下
      // 生成的 onPrimary 是深色调，配亮粉底几乎看不清（首页「扫描本地音乐」
      // 实测）。品牌粉上一律用白字。
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      surface: surface,
      onSurface: isDark ? darkTextPrimary : lightTextPrimary,
      surfaceContainerHighest: surfaceHigh,
      outlineVariant: isDark ? darkOutline : lightOutline,
    );
    final textSecondary = isDark ? darkTextSecondary : lightTextSecondary;

    final isDesktop = switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS => true,
      _ => false,
    };
    final base = ThemeData(brightness: brightness, useMaterial3: true);
    final textTheme = base.textTheme
        .copyWith(
          headlineMedium: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
          headlineSmall: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
          ),
          titleLarge: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
          titleMedium: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          titleSmall: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          bodyLarge: const TextStyle(fontSize: 15),
          bodyMedium: const TextStyle(fontSize: 14),
          bodySmall: TextStyle(fontSize: 12, color: textSecondary),
          labelSmall: TextStyle(fontSize: 11, color: textSecondary),
        )
        .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      // 桌面端用紧凑密度：鼠标精度高，触屏尺寸的行高在桌面上显得松垮
      visualDensity: isDesktop ? VisualDensity.compact : VisualDensity.standard,
      // 水波纹在桌面上显得廉价，桌面只保留高亮
      splashFactory:
          isDesktop ? NoSplash.splashFactory : InkRipple.splashFactory,
      hoverColor: scheme.onSurface.withValues(alpha: 0.05),
      highlightColor: scheme.onSurface.withValues(alpha: 0.06),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        foregroundColor: scheme.onSurface,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w800,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: textSecondary,
        subtitleTextStyle: TextStyle(fontSize: 12, color: textSecondary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusChip),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
          shape: const StadiumBorder(),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outlineVariant),
          shape: const StadiumBorder(),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceHigh,
        selectedColor: accent.withValues(alpha: 0.18),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusChip),
        ),
        labelStyle: TextStyle(fontSize: 13, color: scheme.onSurface),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusChip + 4),
          borderSide: BorderSide.none,
        ),
        hintStyle: TextStyle(color: textSecondary),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        // 桌面宽屏上底部面板不拉满整个窗口
        constraints: const BoxConstraints(maxWidth: 640),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(radiusSheet),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSheet),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surfaceHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusChip + 2),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: isDark ? surfaceHigh : darkSurfaceHigh,
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: const TextStyle(fontSize: 12, color: darkTextPrimary),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.onSurface,
        unselectedLabelColor: textSecondary,
        indicatorColor: accent,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(fontSize: 15),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 64,
        elevation: 0,
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color:
                states.contains(WidgetState.selected)
                    ? scheme.onSurface
                    : textSecondary,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight:
                states.contains(WidgetState.selected)
                    ? FontWeight.w700
                    : FontWeight.w400,
            color:
                states.contains(WidgetState.selected)
                    ? scheme.onSurface
                    : textSecondary,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: background,
        indicatorColor: surfaceHigh,
        selectedIconTheme: IconThemeData(color: scheme.onSurface),
        selectedLabelTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        unselectedIconTheme: IconThemeData(color: textSecondary),
        unselectedLabelTextStyle: TextStyle(fontSize: 12, color: textSecondary),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.onSurface,
        inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.15),
        thumbColor: scheme.onSurface,
        overlayColor: scheme.onSurface.withValues(alpha: 0.08),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(isDesktop ? 8 : 4),
        radius: const Radius.circular(8),
        thumbColor: WidgetStateProperty.all(
          scheme.onSurface.withValues(alpha: 0.25),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? darkSurfaceHigh : darkTextPrimary,
        contentTextStyle: TextStyle(
          color: isDark ? darkTextPrimary : darkBackground,
        ),
        // 缺省取 inversePrimary，在这套配色下是发灰的暗粉，「重试」看着像禁用
        actionTextColor: accent,
        width: isDesktop ? 480 : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusChip),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
        thickness: 0.5,
        space: 1,
      ),
    );
  }
}
