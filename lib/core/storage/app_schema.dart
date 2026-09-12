/// 本地存储 schema 声明与迁移注册表（架构演进设计 §3.2 / S1）。
///
/// 集中声明每个 Box 的目标版本与迁移步骤，避免迁移逻辑散落在各仓库里
/// ——散落的迁移无法保证执行顺序，也无法在启动时统一处理失败降级。
///
/// ## 新增一次迁移的做法
///
/// 1. 提升对应 Box 的 `targetVersion`；
/// 2. 在 [_migrations] 里加一条 [SchemaMigration]（`toVersion` 严格递增）；
/// 3. 在 `test/core/storage/app_schema_test.dart` 补一条断言。
///
/// **必须成对出现**：只改版本号不加步骤会被 [SchemaMigrator] 判定为
/// 步骤表不完整并拒绝迁移（这是刻意的，避免静默跳过迁移）。
library;

import 'package:hive/hive.dart';

import '../logging/app_logger.dart';
import 'schema_migrator.dart';

/// 单个 Box 的迁移结果摘要（供启动日志与降级决策）。
class BoxMigrationReport {
  const BoxMigrationReport({required this.boxName, required this.result});

  final String boxName;
  final MigrationResult result;

  bool get isUsable => result.isUsable;
}

abstract final class AppSchema {
  // ---------- 各 Box 目标版本 ----------
  //
  // 全部初始为 1（与 SchemaMigrator.initialVersion 一致），
  // 表示「与历史数据同构」。S4 收藏迁移到 workId 时提升 favorites 到 2。

  static const int accountVersion = 1;
  static const int favoritesVersion = 1;
  static const int historyVersion = 1;
  static const int playlistsVersion = 1;
  static const int searchHistoryVersion = 1;
  static const int localMusicSettingsVersion = 1;
  static const int appSettingsVersion = 1;
  static const int resumeVersion = 1;

  /// Box 名 → 目标版本。
  static const Map<String, int> targetVersions = <String, int>{
    'musaic_accounts': accountVersion,
    'musaic_favorites': favoritesVersion,
    'musaic_history': historyVersion,
    'musaic_playlists': playlistsVersion,
    'musaic_search_history': searchHistoryVersion,
    'local_music_settings': localMusicSettingsVersion,
    'app_settings': appSettingsVersion,
    'musaic_resume': resumeVersion,
  };

  /// Box 名 → 迁移步骤（按 `toVersion` 升序）。
  ///
  /// 当前为空：尚无 Box 发生结构变更。S4 会在此加入收藏的 v1→v2。
  static List<SchemaMigration> migrationsFor(String boxName) =>
      _migrations[boxName] ?? const <SchemaMigration>[];

  static const Map<String, List<SchemaMigration>> _migrations =
      <String, List<SchemaMigration>>{};

  /// 对一批已打开的 Box 执行迁移。
  ///
  /// [boxes] 为 Box 名 → Box 实例；未在 [targetVersions] 中声明的 Box
  /// 会被跳过（例如测试用 Box）。
  ///
  /// 返回逐 Box 结果；调用方据 [BoxMigrationReport.isUsable] 决定降级。
  static Future<List<BoxMigrationReport>> migrateAll(
    Map<String, Box<String>> boxes, {
    Box<String>? backupBox,
  }) async {
    final reports = <BoxMigrationReport>[];

    for (final entry in boxes.entries) {
      final boxName = entry.key;
      final target = targetVersions[boxName];
      if (target == null) continue; // 未声明的 Box（如迁移备份本身）跳过

      final result = await SchemaMigrator.migrate(
        box: entry.value,
        targetVersion: target,
        migrations: migrationsFor(boxName),
        backupBox: backupBox,
      );
      reports.add(BoxMigrationReport(boxName: boxName, result: result));

      if (!result.isUsable) {
        // 不在此处中断：其余 Box 仍应迁移，且应用需能进入降级模式，
        // 而不是白屏。具体降级行为由调用方决定。
        AppLog.error('Box 迁移不可用，需降级处理：$boxName | $result', tag: 'MusaicSchema');
      }
    }

    return reports;
  }

  /// 是否有任何 Box 处于不可用状态（应用应进入只读降级模式）。
  static bool hasUnusable(List<BoxMigrationReport> reports) =>
      reports.any((r) => !r.isUsable);
}
