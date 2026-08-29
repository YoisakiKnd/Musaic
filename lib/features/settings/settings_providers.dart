import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/network/network_config.dart';
import '../../core/network/network_status.dart';

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

  bool get enableGlass {
    final stored = box.get(_glassKey);
    if (stored != null) return stored == 'true';
    // 功耗计划 PW-06：移动端默认关闭实时模糊（GPU 常驻成本高），
    // 桌面端默认开启；用户显式设置后以设置为准。
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    return !mobile;
  }

  Future<void> setEnableGlass(bool value) =>
      box.put(_glassKey, value ? 'true' : 'false');

  /// 封面取色动态背景：关闭时播放页一律使用品牌渐变。
  bool get dynamicCoverColor => box.get(_dynamicColorKey) != 'false';

  Future<void> setDynamicCoverColor(bool value) =>
      box.put(_dynamicColorKey, value ? 'true' : 'false');

  /// 启动时自动恢复上次播放（断点续播自动续播）：默认关闭。
  bool get autoResumeOnLaunch => box.get(_autoResumeKey) == 'true';

  Future<void> setAutoResumeOnLaunch(bool value) =>
      box.put(_autoResumeKey, value ? 'true' : 'false');

  /// 横屏布局右侧显示歌词（默认显示控制面板）。
  bool get landscapeLyrics => box.get(_landscapeLyricsKey) == 'true';

  Future<void> setLandscapeLyrics(bool value) =>
      box.put(_landscapeLyricsKey, value ? 'true' : 'false');

  /// 蜂窝网络自动降质（功耗计划 PW-09）：默认开启。
  bool get cellularAutoDowngrade => box.get(_cellularDowngradeKey) != 'false';

  Future<void> setCellularAutoDowngrade(bool value) =>
      box.put(_cellularDowngradeKey, value ? 'true' : 'false');

  bool get oledBlack => box.get(_oledKey) == 'true';

  Future<void> setOledBlack(bool value) =>
      box.put(_oledKey, value ? 'true' : 'false');

  /// 歌词时间偏移（毫秒，正值=歌词提前显示/负值=延后）。
  int get lyricOffsetMs => int.tryParse(box.get(_lyricOffsetKey) ?? '') ?? 0;

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
  int? get networkTimeoutSeconds => int.tryParse(box.get(_timeoutKey) ?? '');

  Future<void> setNetworkTimeoutSeconds(int seconds) =>
      box.put(_timeoutKey, seconds.toString());

  static const String _themeModeKey = 'theme_mode';
  static const String _glassKey = 'enable_glass';
  static const String _oledKey = 'oled_black';
  static const String _lyricOffsetKey = 'lyric_offset_ms';
  static const String _qualityKey = 'audio_quality';
  static const String _timeoutKey = 'network_timeout_seconds';
  static const String _cellularDowngradeKey = 'cellular_auto_downgrade';
  static const String _dynamicColorKey = 'dynamic_cover_color';
  static const String _autoResumeKey = 'auto_resume_on_launch';
  static const String _landscapeLyricsKey = 'landscape_lyrics';
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
  /// 蜂窝降档（功耗 PW-09）：high→normal→low，low 保持不变。
  AudioQuality get downgraded => switch (this) {
    AudioQuality.high => AudioQuality.normal,
    _ => AudioQuality.low,
  };

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

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

/// 玻璃/模糊效果开关（持久化；性能预算 §10.2：低端机可关闭实时模糊）。
class EnableGlassNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(appSettingsRepositoryProvider).enableGlass;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(appSettingsRepositoryProvider).setEnableGlass(value);
  }
}

final enableGlassProvider = NotifierProvider<EnableGlassNotifier, bool>(
  EnableGlassNotifier.new,
);

/// OLED 纯黑背景开关（持久化；仅深色主题下生效）。
class OledBlackNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(appSettingsRepositoryProvider).oledBlack;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(appSettingsRepositoryProvider).setOledBlack(value);
  }
}

final oledBlackProvider = NotifierProvider<OledBlackNotifier, bool>(
  OledBlackNotifier.new,
);

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

final lyricOffsetMsProvider = NotifierProvider<LyricOffsetNotifier, int>(
  LyricOffsetNotifier.new,
);

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
      AudioQualityNotifier.new,
    );

/// 实际生效的音质档位（功耗计划 PW-09）：
/// 开启「蜂窝自动降质」且当前不在 Wi-Fi/以太网时降一档，
/// 判定失败一律视为 Wi-Fi（fail-open 不降档）。
final effectiveAudioQualityProvider = Provider<AudioQuality>((ref) {
  final quality = ref.watch(audioQualityProvider);
  if (!ref.watch(cellularAutoDowngradeProvider)) return quality;
  final onWifi = ref.watch(connectivityIsWifiProvider).valueOrNull ?? true;
  return onWifi ? quality : quality.downgraded;
});

/// 蜂窝网络自动降质开关（持久化；功耗 PW-09）。
class CellularAutoDowngradeNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.watch(appSettingsRepositoryProvider).cellularAutoDowngrade;

  Future<void> set(bool value) async {
    state = value;
    await ref
        .read(appSettingsRepositoryProvider)
        .setCellularAutoDowngrade(value);
  }
}

final cellularAutoDowngradeProvider =
    NotifierProvider<CellularAutoDowngradeNotifier, bool>(
      CellularAutoDowngradeNotifier.new,
    );

/// 封面取色动态背景开关（持久化）。
class DynamicCoverColorNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(appSettingsRepositoryProvider).dynamicCoverColor;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(appSettingsRepositoryProvider).setDynamicCoverColor(value);
  }
}

final dynamicCoverColorProvider =
    NotifierProvider<DynamicCoverColorNotifier, bool>(
      DynamicCoverColorNotifier.new,
    );

/// 启动自动恢复上次播放开关（持久化；默认关闭）。
class AutoResumeOnLaunchNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(appSettingsRepositoryProvider).autoResumeOnLaunch;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(appSettingsRepositoryProvider).setAutoResumeOnLaunch(value);
  }
}

final autoResumeOnLaunchProvider =
    NotifierProvider<AutoResumeOnLaunchNotifier, bool>(
      AutoResumeOnLaunchNotifier.new,
    );

/// 横屏右侧歌词布局开关（持久化；默认显示控制面板）。
class LandscapeLyricsNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(appSettingsRepositoryProvider).landscapeLyrics;

  Future<void> set(bool value) async {
    state = value;
    await ref.read(appSettingsRepositoryProvider).setLandscapeLyrics(value);
  }
}

final landscapeLyricsProvider = NotifierProvider<LandscapeLyricsNotifier, bool>(
  LandscapeLyricsNotifier.new,
);

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
    NotifierProvider<NetworkTimeoutNotifier, int>(NetworkTimeoutNotifier.new);
