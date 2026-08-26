import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// 应用设置仓库：外观与性能偏好持久化（Hive）。
class AppSettingsRepository {
  AppSettingsRepository({required this.box});

  static const String boxName = 'app_settings';

  final Box<String> box;

  ThemeMode get themeMode => switch (box.get(_themeModeKey)) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };

  Future<void> setThemeMode(ThemeMode mode) =>
      box.put(_themeModeKey, mode.name);

  bool get enableGlass => box.get(_glassKey) != 'false';

  Future<void> setEnableGlass(bool value) =>
      box.put(_glassKey, value ? 'true' : 'false');

  bool get oledBlack => box.get(_oledKey) == 'true';

  Future<void> setOledBlack(bool value) =>
      box.put(_oledKey, value ? 'true' : 'false');

  static const String _themeModeKey = 'theme_mode';
  static const String _glassKey = 'enable_glass';
  static const String _oledKey = 'oled_black';
}

final appSettingsRepositoryProvider = Provider<AppSettingsRepository>((ref) {
  throw StateError('appSettingsRepositoryProvider 必须在启动时 override');
});

/// 主题模式（持久化；默认深色，符合设计令牌「深色优先」）。
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ref.watch(appSettingsRepositoryProvider).themeMode;

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await ref.read(appSettingsRepositoryProvider).setThemeMode(mode);
  }
}

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

/// 玻璃/模糊效果开关（持久化；性能预算 §10.2：低端机可关闭实时模糊）。
class EnableGlassNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(appSettingsRepositoryProvider).enableGlass;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(appSettingsRepositoryProvider).setEnableGlass(value);
  }
}

final enableGlassProvider =
    NotifierProvider<EnableGlassNotifier, bool>(EnableGlassNotifier.new);

/// OLED 纯黑背景开关（持久化；仅深色主题下生效）。
class OledBlackNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(appSettingsRepositoryProvider).oledBlack;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(appSettingsRepositoryProvider).setOledBlack(value);
  }
}

final oledBlackProvider =
    NotifierProvider<OledBlackNotifier, bool>(OledBlackNotifier.new);
