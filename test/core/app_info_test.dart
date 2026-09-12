import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/app_info.dart';

/// 版本号单一来源守护（迭代计划 I0-07 / E3）。
///
/// `AppInfo` 与 `pubspec.yaml` 必须一致，防止「关于」页显示
/// 与实际发布版本脱节。
void main() {
  test('AppInfo.version 与 pubspec.yaml 的 version 一致', () {
    final pubspec = File('pubspec.yaml').readAsLinesSync();
    final line = pubspec.firstWhere(
      (l) => l.startsWith('version:'),
      orElse: () => throw StateError('pubspec.yaml 缺少 version 字段'),
    );
    // 形如 `version: 0.1.0+1`
    final raw = line.substring('version:'.length).trim();
    final parts = raw.split('+');
    final expectedVersion = parts.first;
    final expectedBuild = parts.length > 1 ? parts[1] : '';

    expect(
      AppInfo.version,
      expectedVersion,
      reason: 'AppInfo.version 与 pubspec 不一致：请同步 lib/core/app_info.dart',
    );
    if (expectedBuild.isNotEmpty) {
      expect(
        AppInfo.buildNumber,
        expectedBuild,
        reason: 'AppInfo.buildNumber 与 pubspec 不一致',
      );
    }
  });

  test('versionLabel 由 version 与 buildNumber 组合', () {
    expect(AppInfo.versionLabel, '${AppInfo.version}+${AppInfo.buildNumber}');
  });
}
