import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/network/network_config.dart';

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

  /// 歌词时间偏移（毫秒，正值=歌词提前显示/负值=延后）。
  int get lyricOffsetMs =>
      int.tryParse(box.get(_lyricOffsetKey) ?? '') ?? 0;

  Future<void> setLyricOffsetMs(int value) =>
      box.put(_lyricOffsetKey, value.toString());

  /// 播放音质档位：low(128k) / normal(192k) / high(320k+)。
  AudioQuality get audioQuality => switch (box.get(_qualityKey)) {
        'low' => AudioQuality.low,
        'high' => AudioQuality.high,
        _ => AudioQuality.normal,
      };

  Future<void> setAudioQuality(AudioQuality quality) =>
      box.put(_qualityKey, quality.name);

  /// 渠道网络请求超时（秒）；null 表示用默认档位。
  int? get networkTimeoutSeconds =>
      int.tryParse(box.get(_timeoutKey) ?? '');

  Future<void> setNetworkTimeoutSeconds(int seconds) =>
      box.put(_timeoutKey, seconds.toString());

  static const String _themeModeKey = 'theme_mode';
  static const String _glassKey = 'enable_glass';
  static const String _oledKey = 'oled_black';
  static const String _lyricOffsetKey = 'lyric_offset_ms';
  static const String _qualityKey = 'audio_quality';
  static const String _timeoutKey = 'network_timeout_seconds';
}

/// 播放音质档位（各渠道映射到自身支持的最接近码率）。
enum AudioQuality {
  /// 流畅优先（约 128kbps）。
  low,

  /// 标准（约 192kbps）。
  normal,

  /// 高品质保真（320kbps / 无损优先）。
  high,
}

/// 档位 → 渠道码率（bps）映射。
extension AudioQualityBits on AudioQuality {
  /// 网易云 /api/song/enhance/player/url 的 br 参数。
  int get neteaseBr => switch (this) {
        AudioQuality.low => 128000,
        AudioQuality.normal => 192000,
        AudioQuality.high => 320000,
      };

  /// YTM googlevideo 格式的码率上限。
  int get ytmMaxBitrate => switch (this) {
        AudioQuality.low => 130000,
        AudioQuality.normal => 260000,
        AudioQuality.high => 0, // 0 = 不设上限，取最高
      };
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

/// 歌词时间偏移（毫秒）。
class LyricOffsetNotifier extends Notifier<int> {
  @override
  int build() => ref.watch(appSettingsRepositoryProvider).lyricOffsetMs;

  Future<void> set(int ms) async {
    final clamped = ms.clamp(-10000, 10000);
    state = clamped;
    await ref.read(appSettingsRepositoryProvider).setLyricOffsetMs(clamped);
  }
}

final lyricOffsetMsProvider =
    NotifierProvider<LyricOffsetNotifier, int>(LyricOffsetNotifier.new);

/// 播放音质档位（对下次 resolveStream 生效，不打断当前播放）。
class AudioQualityNotifier extends Notifier<AudioQuality> {
  @override
  AudioQuality build() => ref.watch(appSettingsRepositoryProvider).audioQuality;

  Future<void> set(AudioQuality quality) async {
    state = quality;
    await ref.read(appSettingsRepositoryProvider).setAudioQuality(quality);
  }
}

final audioQualityProvider =
    NotifierProvider<AudioQualityNotifier, AudioQuality>(
        AudioQualityNotifier.new);

/// 渠道网络请求超时（秒）：写设置 + 即时覆写 [NetworkConfig]（请求级生效）。
class NetworkTimeoutNotifier extends Notifier<int> {
  @override
  int build() {
    final stored =
        ref.watch(appSettingsRepositoryProvider).networkTimeoutSeconds;
    NetworkConfig.instance.restore(stored);
    return NetworkConfig.instance.seconds;
  }

  Future<void> set(int seconds) async {
    NetworkConfig.instance.set(seconds);
    state = NetworkConfig.instance.seconds;
    await ref
        .read(appSettingsRepositoryProvider)
        .setNetworkTimeoutSeconds(state);
  }
}

final networkTimeoutSecondsProvider =
    NotifierProvider<NetworkTimeoutNotifier, int>(
        NetworkTimeoutNotifier.new);
