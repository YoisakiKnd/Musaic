import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/network/network_status.dart';
import 'package:musaic/features/settings/settings_providers.dart';

/// 功耗计划设置项验证：PW-06 玻璃默认值分级、PW-09 蜂窝自动降档。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box<String> box;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_pw_settings');
    Hive.init(tempDir.path);
    box = await Hive.openBox<String>('pw_app_settings');
  });

  tearDownAll(() async {
    await box.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  tearDown(() async {
    await box.clear();
    debugDefaultTargetPlatformOverride = null;
  });

  group('PW-06：玻璃效果默认值分级', () {
    test('移动端（Android）默认关闭', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final repository = AppSettingsRepository(box: box);
      expect(repository.enableGlass, isFalse);
    });

    test('移动端（iOS）默认关闭', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final repository = AppSettingsRepository(box: box);
      expect(repository.enableGlass, isFalse);
    });

    test('桌面端默认开启；用户显式设置优先', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final repository = AppSettingsRepository(box: box);
      expect(repository.enableGlass, isTrue);

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      // 用户显式开启后，移动端也生效
      await repository.setEnableGlass(true);
      expect(repository.enableGlass, isTrue);
    });
  });

  group('PW-09：蜂窝自动降档矩阵', () {
    Future<ProviderContainer> makeContainer({
      required AudioQuality quality,
      required bool cellularDowngrade,
      required bool onWifi,
    }) async {
      final container = ProviderContainer(
        overrides: [
          audioQualityProvider.overrideWith(() => _FixedQuality(quality)),
          cellularAutoDowngradeProvider.overrideWith(
            () => _FixedCellular(cellularDowngrade),
          ),
          connectivityIsWifiProvider.overrideWith(
            (ref) => Stream.value(onWifi),
          ),
        ],
      );
      // 等待 StreamProvider 首值就绪，避免 valueOrNull 为 null 被 fail-open
      await container
          .read(connectivityIsWifiProvider.future)
          .catchError((_) => true);
      await Future<void>.delayed(Duration.zero);
      return container;
    }

    test('Wi-Fi：保持用户档位', () async {
      final container = await makeContainer(
        quality: AudioQuality.high,
        cellularDowngrade: true,
        onWifi: true,
      );
      expect(container.read(effectiveAudioQualityProvider), AudioQuality.high);
      container.dispose();
    });

    test('蜂窝 + 开关开启：降一档', () async {
      final container = await makeContainer(
        quality: AudioQuality.high,
        cellularDowngrade: true,
        onWifi: false,
      );
      expect(
        container.read(effectiveAudioQualityProvider),
        AudioQuality.normal,
      );
      container.dispose();
    });

    test('蜂窝 + 已是最低档：保持 low', () async {
      final container = await makeContainer(
        quality: AudioQuality.low,
        cellularDowngrade: true,
        onWifi: false,
      );
      expect(container.read(effectiveAudioQualityProvider), AudioQuality.low);
      container.dispose();
    });

    test('蜂窝 + 开关关闭：保持用户档位', () async {
      final container = await makeContainer(
        quality: AudioQuality.high,
        cellularDowngrade: false,
        onWifi: false,
      );
      expect(container.read(effectiveAudioQualityProvider), AudioQuality.high);
      container.dispose();
    });

    test('网络未知（fail-open）：不降档', () async {
      final container = ProviderContainer(
        overrides: [
          audioQualityProvider.overrideWith(
            () => _FixedQuality(AudioQuality.high),
          ),
          cellularAutoDowngradeProvider.overrideWith(
            () => _FixedCellular(true),
          ),
          // 无 override：测试环境插件缺失 → valueOrNull 为 null → 视为 Wi-Fi
        ],
      );
      expect(container.read(effectiveAudioQualityProvider), AudioQuality.high);
      container.dispose();
    });
  });
}

class _FixedQuality extends AudioQualityNotifier {
  _FixedQuality(this.value);

  final AudioQuality value;

  @override
  AudioQuality build() => value;
}

class _FixedCellular extends CellularAutoDowngradeNotifier {
  _FixedCellular(this.value);

  final bool value;

  @override
  bool build() => value;
}
