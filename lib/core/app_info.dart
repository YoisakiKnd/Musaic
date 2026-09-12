/// 应用元信息（版本号单一来源）。
///
/// 版本号原先硬编码在 `settings_page.dart` 的「关于」页，
/// 与 `pubspec.yaml` 形成两处来源、极易漂移。
/// 此处集中一处，并由 `test/core/app_info_test.dart` 断言其与
/// `pubspec.yaml` 的 `version:` 一致（迭代计划 I0-07 / E3）。
library;

abstract final class AppInfo {
  /// 语义化版本（不含 build number）。
  static const String version = '0.1.0';

  /// 构建号（对应 pubspec 的 `+N`）。
  static const String buildNumber = '1';

  /// 展示用完整版本串。
  static const String versionLabel = '$version+$buildNumber';

  static const String appName = 'Musaic · 音乐拼图';

  static const String repositoryUrl = 'https://github.com/YoisakiKnd/Musaic';
}
