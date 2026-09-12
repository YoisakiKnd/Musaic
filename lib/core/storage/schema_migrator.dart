/// 本地存储 schema 版本化与迁移（架构演进设计 §3.2）。
///
/// 背景：项目有 8 个 Hive Box，此前**全部裸存、无版本号、无迁移钩子**。
/// 设置项靠 `box.get(key) == 'true'` 这类弱类型约定，一旦要改字段语义
/// 就只能「读不出来回默认」——用户数据静默丢失，且无法写迁移。
///
/// 本模块提供有序、可回滚、可抗进程中断的迁移机制。
///
/// ## 为什么必须有磁盘备份（而不只是内存快照）
///
/// 迁移过程中可能发生**进程被杀**（移动端被系统回收、用户强杀）。
/// 此时异常处理器根本不会运行，内存快照随之消失，Box 停留在
/// 「迁移到一半 + 版本号仍是旧值」的状态——下次启动会**重复迁移**，
/// 对非幂等步骤（如「把键 A 改名成 B」）就会丢数据。
///
/// 因此采用「备份即进行中标记」：
/// 1. 迁移前把整个 Box 写入备份 Box（**落盘**）；
/// 2. 执行迁移步骤；
/// 3. 成功后写新版本号并**删除备份**；
/// 4. 启动时若发现备份仍存在 → 说明上次没走完 → 先回滚再决定。
///
/// 备份的存在性本身就是「迁移未完成」的标记，无需额外的状态机。
library;

import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:meta/meta.dart';

import '../logging/app_logger.dart';

/// 版本号与备份的保留键前缀。
///
/// 迁移步骤遍历 Box 时必须跳过这些键（用 [SchemaMigrator.dataKeys] 取值），
/// 否则会把版本号当业务数据搬走。
const String _reservedPrefix = '__musaic__';

/// 单步迁移：把 Box 从 `toVersion - 1` 迁到 `toVersion`。
@immutable
class SchemaMigration {
  const SchemaMigration({
    required this.toVersion,
    required this.description,
    required this.apply,
  });

  /// 本步骤完成后的版本号（必须严格递增，从 2 开始）。
  final int toVersion;

  /// 人类可读说明，写入日志便于事后排查。
  final String description;

  /// 迁移动作。抛异常即视为失败，调用方会回滚整个 Box。
  final Future<void> Function(Box<String> box) apply;

  @override
  String toString() => 'SchemaMigration(v$toVersion: $description)';
}

enum MigrationOutcome {
  /// 版本已是最新，未做任何改动。
  upToDate,

  /// 成功执行了若干步骤。
  migrated,

  /// 迁移失败，已回滚到迁移前状态（版本号保持不变）。
  failed,

  /// 数据版本高于本应用支持的版本（用户装过更新的版本）。
  ///
  /// **不做任何改动**：降级迁移会丢字段。调用方应进入只读降级模式。
  dataNewerThanApp,

  /// 检测到上次迁移未完成（备份残留），已从备份恢复。
  ///
  /// 恢复后仍会继续尝试迁移（若备份数据版本低于目标）。
  recoveredFromInterrupted,
}

@immutable
class MigrationResult {
  const MigrationResult({
    required this.outcome,
    required this.fromVersion,
    required this.toVersion,
    this.error,
    this.appliedSteps = 0,
  });

  final MigrationOutcome outcome;

  /// 迁移前的版本号（无法确定时为 [SchemaMigrator.initialVersion]）。
  final int fromVersion;

  /// 迁移后的版本号。
  final int toVersion;

  /// 失败原因（仅 [MigrationOutcome.failed] 时非空）。
  final Object? error;

  /// 实际执行的步骤数。
  final int appliedSteps;

  /// 是否可以安全地把该 Box 当正常数据使用。
  ///
  /// [MigrationOutcome.failed] 与 [dataNewerThanApp] 为 false。
  bool get isUsable =>
      outcome != MigrationOutcome.failed &&
      outcome != MigrationOutcome.dataNewerThanApp;

  @override
  String toString() =>
      'MigrationResult(${outcome.name}, v$fromVersion→v$toVersion, '
      'steps=$appliedSteps${error == null ? '' : ', error=$error'})';
}

/// Box 迁移器。
abstract final class SchemaMigrator {
  /// 无版本号的历史数据一律视为该版本（兼容现有用户数据）。
  static const int initialVersion = 1;

  /// 备份 Box 名。与业务 Box 分离，避免被迁移步骤波及。
  static const String backupBoxName = 'musaic_migration_backup';

  static String versionKey(String boxName) =>
      '$_reservedPrefix schema $boxName';

  static String backupKey(String boxName) => '$_reservedPrefix backup $boxName';

  /// 读取 Box 当前 schema 版本（缺失视为 [initialVersion]）。
  static int readVersion(Box<String> box) {
    final raw = box.get(versionKey(box.name));
    if (raw == null) return initialVersion;
    return int.tryParse(raw) ?? initialVersion;
  }

  /// 业务数据键（已剔除保留键）。
  ///
  /// **迁移步骤必须用它遍历**，否则会把版本号/备份当业务数据搬走。
  static List<String> dataKeys(Box<String> box) => box.keys
      .map((k) => '$k')
      .where((k) => !k.startsWith(_reservedPrefix))
      .toList(growable: false);

  /// 执迁移。
  ///
  /// [backupBox] 用于落盘备份；为 null 时退化为**仅内存快照**，
  /// 此时无法抵御进程被杀（仅建议测试或确实无需持久化的场景使用）。
  ///
  /// 注意：本方法不负责打开 Box，也不负责把 [MigrationOutcome.isUsable]
  /// 为 false 的 Box 切到只读——那属于调用方的降级策略。
  static Future<MigrationResult> migrate({
    required Box<String> box,
    required int targetVersion,
    required List<SchemaMigration> migrations,
    Box<String>? backupBox,
  }) async {
    final boxName = box.name;
    var version = readVersion(box);

    // 0) 先处理「上次迁移没走完」：备份还在说明进程被杀过。
    var recovered = false;
    if (backupBox != null && backupBox.containsKey(backupKey(boxName))) {
      AppLog.warning('检测到未完成的迁移，从备份恢复：$boxName', tag: 'MusaicSchema');
      final ok = await _restoreFromBackup(box: box, backupBox: backupBox);
      if (!ok) {
        return MigrationResult(
          outcome: MigrationOutcome.failed,
          fromVersion: version,
          toVersion: version,
          error: StateError('备份恢复失败：$boxName'),
        );
      }
      recovered = true;
      version = readVersion(box);
    }

    // 1) 数据版本高于应用：绝不降级迁移（会丢字段），交给调用方降级处理。
    if (version > targetVersion) {
      AppLog.error(
        '数据版本($version)高于应用支持($targetVersion)，拒绝迁移：$boxName',
        tag: 'MusaicSchema',
      );
      return MigrationResult(
        outcome: MigrationOutcome.dataNewerThanApp,
        fromVersion: version,
        toVersion: version,
      );
    }

    if (version == targetVersion) {
      return MigrationResult(
        outcome:
            recovered
                ? MigrationOutcome.recoveredFromInterrupted
                : MigrationOutcome.upToDate,
        fromVersion: version,
        toVersion: version,
      );
    }

    // 2) 校验步骤表：必须覆盖 version+1 .. targetVersion 且严格递增。
    final pending = _validateAndSelect(migrations, version, targetVersion);
    if (pending == null) {
      return MigrationResult(
        outcome: MigrationOutcome.failed,
        fromVersion: version,
        toVersion: version,
        error: StateError('迁移步骤表不完整或版本号非严格递增：$boxName'),
      );
    }

    // 3) 落盘备份（备份存在 = 迁移进行中标记）
    final snapshot = Map<String, String>.from(box.toMap());
    if (backupBox != null) {
      try {
        await backupBox.put(backupKey(boxName), jsonEncode(snapshot));
      } catch (e) {
        // 备份写不进去就**不能开始迁移**：否则失败时无路可退。
        AppLog.error('迁移前备份失败，已中止：$boxName | $e', tag: 'MusaicSchema');
        return MigrationResult(
          outcome: MigrationOutcome.failed,
          fromVersion: version,
          toVersion: version,
          error: e,
        );
      }
    }

    // 4) 逐步执行
    final from = version;
    var applied = 0;
    try {
      for (final step in pending) {
        await step.apply(box);
        version = step.toVersion;
        applied++;
      }
      await box.put(versionKey(boxName), '$version');
    } catch (e, st) {
      AppLog.error(
        '迁移失败，回滚：$boxName | $e',
        tag: 'MusaicSchema',
        stackTrace: st,
      );
      await _restoreSnapshot(box: box, snapshot: snapshot);
      await box.put(versionKey(boxName), '$from');
      if (backupBox != null) {
        try {
          await backupBox.delete(backupKey(boxName));
        } catch (_) {}
      }
      return MigrationResult(
        outcome: MigrationOutcome.failed,
        fromVersion: from,
        toVersion: from,
        error: e,
        appliedSteps: applied,
      );
    }

    // 5) 成功：清理备份
    if (backupBox != null) {
      try {
        await backupBox.delete(backupKey(boxName));
      } catch (e) {
        // 备份删不掉不影响正确性：下次启动会走「恢复」路径，
        // 而恢复用的正是迁移**后**的数据（版本号已更新），结果幂等。
        AppLog.warning('迁移成功但备份清理失败：$boxName | $e', tag: 'MusaicSchema');
      }
    }

    AppLog.info(
      '迁移完成：$boxName v$from→v$version（$applied 步）',
      tag: 'MusaicSchema',
    );
    return MigrationResult(
      outcome:
          recovered
              ? MigrationOutcome.recoveredFromInterrupted
              : MigrationOutcome.migrated,
      fromVersion: from,
      toVersion: version,
      appliedSteps: applied,
    );
  }

  /// 校验步骤表能恰好覆盖 [from] → [to]，返回需执行的步骤。
  ///
  /// 返回 null 表示步骤表非法（缺失步骤 / 版本号重复或倒退）。
  /// 这类错误必须在**动数据之前**发现。
  static List<SchemaMigration>? _validateAndSelect(
    List<SchemaMigration> migrations,
    int from,
    int to,
  ) {
    final sorted = [...migrations]
      ..sort((a, b) => a.toVersion.compareTo(b.toVersion));
    final pending = <SchemaMigration>[];
    var expected = from + 1;
    for (final step in sorted) {
      if (step.toVersion < expected) continue; // 已应用的步骤
      if (step.toVersion != expected) return null; // 缺口或重复
      pending.add(step);
      expected++;
    }
    return expected == to + 1 ? pending : null;
  }

  /// 用备份内容整体替换 Box（先清后写，因为要保证多余键也被清掉）。
  static Future<bool> _restoreFromBackup({
    required Box<String> box,
    required Box<String> backupBox,
  }) async {
    final raw = backupBox.get(backupKey(box.name));
    if (raw == null) return false;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      final snapshot = <String, String>{
        for (final e in decoded.entries) '${e.key}': '${e.value}',
      };
      await _restoreSnapshot(box: box, snapshot: snapshot);
      await backupBox.delete(backupKey(box.name));
      AppLog.info('已从备份恢复：${box.name}', tag: 'MusaicSchema');
      return true;
    } catch (e) {
      AppLog.error('备份解析失败：${box.name} | $e', tag: 'MusaicSchema');
      return false;
    }
  }

  /// 恢复快照：先写后删，任一时刻磁盘上都保留可用数据。
  ///
  /// 与 [LibraryRepository.restoreSnapshot] 同一策略：不用「先 clear 再写回」，
  /// 否则中途失败会留下空库。
  static Future<void> _restoreSnapshot({
    required Box<String> box,
    required Map<String, String> snapshot,
  }) async {
    await box.putAll(snapshot);
    final stale = dataKeys(
      box,
    ).where((k) => !snapshot.containsKey(k)).toList(growable: false);
    if (stale.isNotEmpty) await box.deleteAll(stale);
  }
}
