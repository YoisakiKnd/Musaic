import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/storage/app_schema.dart';
import 'package:musaic/core/storage/schema_migrator.dart';
import 'package:musaic/features/auth/data/account_repository.dart';
import 'package:musaic/features/library/data/library_repository.dart';
import 'package:musaic/features/player/data/resume_repository.dart';
import 'package:musaic/features/search/data/search_history_repository.dart';
import 'package:musaic/features/settings/data/local_music_settings_repository.dart';
import 'package:musaic/features/settings/settings_providers.dart';

/// 存储 schema 注册表一致性（架构演进设计 §3.2 / S1）。
///
/// 这类「声明表」最容易出的问题是**与实际 Box 名脱节**：
/// 改了常量名但忘了更新注册表，迁移就会静默跳过某个 Box，
/// 直到用户数据出问题才被发现。因此这里用真实常量反向校验。
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_app_schema_test');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('注册表覆盖全部真实 Box', () {
    test('每个仓库声明的 Box 都在 targetVersions 中', () {
      final declared = <String>{
        AccountRepository.accountBoxName,
        LibraryRepository.favoritesBoxName,
        LibraryRepository.historyBoxName,
        LibraryRepository.playlistsBoxName,
        SearchHistoryRepository.boxName,
        LocalMusicSettingsRepository.boxName,
        AppSettingsRepository.boxName,
        ResumeRepository.boxName,
      };

      for (final name in declared) {
        expect(
          AppSchema.targetVersions.containsKey(name),
          isTrue,
          reason:
              'Box「$name」未在 AppSchema.targetVersions 中声明，'
              '迁移会被静默跳过',
        );
      }
      expect(AppSchema.targetVersions.length, declared.length);
    });

    test('迁移备份 Box 本身不被当作业务 Box 迁移', () {
      expect(
        AppSchema.targetVersions.containsKey(SchemaMigrator.backupBoxName),
        isFalse,
        reason: '备份 Box 若被迁移会自我引用',
      );
    });
  });

  group('目标版本合法', () {
    test('所有目标版本 ≥ initialVersion', () {
      for (final entry in AppSchema.targetVersions.entries) {
        expect(
          entry.value,
          greaterThanOrEqualTo(SchemaMigrator.initialVersion),
          reason: '${entry.key} 的目标版本低于初始版本',
        );
      }
    });

    test('已声明版本 > 1 的 Box 必须提供迁移步骤（防止静默跳过）', () {
      for (final entry in AppSchema.targetVersions.entries) {
        if (entry.value <= SchemaMigrator.initialVersion) continue;
        final steps = AppSchema.migrationsFor(entry.key);
        expect(
          steps,
          isNotEmpty,
          reason:
              '${entry.key} 声明了 v${entry.value} 但没有迁移步骤，'
              'SchemaMigrator 会拒绝迁移',
        );
        // 步骤必须能恰好覆盖 1 → target
        expect(
          steps.map((s) => s.toVersion).toList(),
          List<int>.generate(entry.value - 1, (i) => i + 2),
          reason: '${entry.key} 的迁移步骤未恰好覆盖 v1→v${entry.value}',
        );
      }
    });

    test('未声明的 Box 返回空步骤表（不抛异常）', () {
      expect(AppSchema.migrationsFor('not_a_real_box'), isEmpty);
    });
  });

  group('migrateAll 行为', () {
    test('全部 v1 时是 no-op（现有用户升级后数据不动）', () async {
      final boxes = <String, Box<String>>{};
      for (final name in AppSchema.targetVersions.keys) {
        boxes[name] = await Hive.openBox<String>(
          'test_$name${DateTime.now().microsecondsSinceEpoch}',
        );
      }
      final backup = await Hive.openBox<String>(
        'test_backup_${DateTime.now().microsecondsSinceEpoch}',
      );

      // 写入一些「用户数据」
      for (final box in boxes.values) {
        await box.put('user_key', 'user_value');
      }

      final reports = await AppSchema.migrateAll(boxes, backupBox: backup);

      expect(reports, hasLength(AppSchema.targetVersions.length));
      expect(AppSchema.hasUnusable(reports), isFalse);
      for (final report in reports) {
        expect(report.result.outcome, MigrationOutcome.upToDate);
      }
      // 数据原封不动
      for (final box in boxes.values) {
        expect(box.get('user_key'), 'user_value');
      }

      for (final box in boxes.values) {
        await box.deleteFromDisk();
      }
      await backup.deleteFromDisk();
    });

    test('未声明的 Box 被跳过而非报错', () async {
      final box = await Hive.openBox<String>(
        'test_undeclared_${DateTime.now().microsecondsSinceEpoch}',
      );
      await box.put('a', '1');

      final reports = await AppSchema.migrateAll(<String, Box<String>>{
        'totally_unknown_box': box,
      });

      expect(reports, isEmpty);
      expect(box.get('a'), '1');
      await box.deleteFromDisk();
    });

    test('单个 Box 不可用时，其余 Box 仍完成迁移且结果被标记', () async {
      // 必须用**注册表里真实存在**的 Box 名，否则会被当作未声明 Box 跳过，
      // 测试就会「因为错误的原因」通过。
      const goodName = LibraryRepository.favoritesBoxName;
      const badName = LibraryRepository.historyBoxName;

      final good = await Hive.openBox<String>(goodName);
      final bad = await Hive.openBox<String>(badName);
      await good.clear();
      await bad.clear();

      await good.put('user_key', 'user_value');
      // 制造「数据版本高于应用」→ 不可用
      await bad.put(SchemaMigrator.versionKey(badName), '99');

      final backup = await Hive.openBox<String>(
        'backup_${DateTime.now().microsecondsSinceEpoch}',
      );

      final reports = await AppSchema.migrateAll(<String, Box<String>>{
        goodName: good,
        badName: bad,
      }, backupBox: backup);

      expect(reports, hasLength(2));

      final goodReport = reports.firstWhere((r) => r.boxName == goodName);
      final badReport = reports.firstWhere((r) => r.boxName == badName);

      expect(goodReport.isUsable, isTrue, reason: '一个 Box 不可用不应影响另一个');
      expect(good.get('user_key'), 'user_value', reason: '可用 Box 的数据不受影响');

      expect(badReport.isUsable, isFalse);
      expect(badReport.result.outcome, MigrationOutcome.dataNewerThanApp);
      expect(AppSchema.hasUnusable(reports), isTrue);
      // 高版本数据绝不被改动
      expect(SchemaMigrator.readVersion(bad), 99);

      await good.deleteFromDisk();
      await bad.deleteFromDisk();
      await backup.deleteFromDisk();
    });
  });
}
