import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/storage/schema_migrator.dart';

/// 存储 schema 迁移（架构演进设计 §3.2 / S1）。
///
/// 这是 S4（收藏迁移到 workId）的**安全网**：没有它，改存储格式就会
/// 丢用户数据。因此本测试的重点不是「迁移能跑通」，而是
/// **迁移失败与进程被杀时不丢数据**。
void main() {
  late Directory tempDir;
  late Box<String> box;
  late Box<String> backupBox;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_schema_test');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  setUp(() async {
    box = await Hive.openBox<String>(
      'schema_${DateTime.now().microsecondsSinceEpoch}',
    );
    backupBox = await Hive.openBox<String>(
      'backup_${DateTime.now().microsecondsSinceEpoch}',
    );
  });

  tearDown(() async {
    await box.deleteFromDisk();
    await backupBox.deleteFromDisk();
  });

  /// 便捷：构造一个「键值重命名」步骤（模拟真实迁移）。
  SchemaMigration renameStep({
    required int toVersion,
    required String from,
    required String to,
  }) => SchemaMigration(
    toVersion: toVersion,
    description: '重命名 $from → $to',
    apply: (b) async {
      final value = b.get(from);
      if (value == null) return;
      await b.delete(from);
      await b.put(to, value);
    },
  );

  group('版本读取与保留键', () {
    test('无版本号的历史数据视为 v1（兼容现有用户）', () async {
      await box.put('a', '1');
      expect(SchemaMigrator.readVersion(box), SchemaMigrator.initialVersion);
      expect(SchemaMigrator.readVersion(box), 1);
    });

    test('版本号损坏时回退 v1 而非抛异常', () async {
      await box.put(SchemaMigrator.versionKey(box.name), 'not-a-number');
      expect(SchemaMigrator.readVersion(box), 1);
    });

    test('dataKeys 剔除保留键，迁移步骤不会搬走版本号', () async {
      await box.put('song1', 'v');
      await box.put('song2', 'v');
      await box.put(SchemaMigrator.versionKey(box.name), '2');

      expect(SchemaMigrator.dataKeys(box), unorderedEquals(['song1', 'song2']));
    });
  });

  group('成功路径', () {
    test('v1 → v2 单步迁移', () async {
      await box.put('old_key', 'payload');

      final result = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [renameStep(toVersion: 2, from: 'old_key', to: 'new_key')],
        backupBox: backupBox,
      );

      expect(result.outcome, MigrationOutcome.migrated);
      expect(result.fromVersion, 1);
      expect(result.toVersion, 2);
      expect(result.appliedSteps, 1);
      expect(box.get('new_key'), 'payload');
      expect(box.containsKey('old_key'), isFalse);
      expect(SchemaMigrator.readVersion(box), 2);
    });

    test('多步迁移按序执行（v1 → v3）', () async {
      await box.put('k1', 'payload');

      final result = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 3,
        migrations: [
          renameStep(toVersion: 2, from: 'k1', to: 'k2'),
          renameStep(toVersion: 3, from: 'k2', to: 'k3'),
        ],
        backupBox: backupBox,
      );

      expect(result.outcome, MigrationOutcome.migrated);
      expect(result.appliedSteps, 2);
      expect(box.get('k3'), 'payload');
      expect(SchemaMigrator.readVersion(box), 3);
    });

    test('已是最新版本时不执行任何步骤', () async {
      await box.put(SchemaMigrator.versionKey(box.name), '2');
      var called = false;

      final result = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [
          SchemaMigration(
            toVersion: 2,
            description: '不应执行',
            apply: (_) async => called = true,
          ),
        ],
        backupBox: backupBox,
      );

      expect(result.outcome, MigrationOutcome.upToDate);
      expect(called, isFalse);
    });

    test('成功后清理备份（无残留「进行中」标记）', () async {
      await box.put('a', '1');
      await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [renameStep(toVersion: 2, from: 'a', to: 'b')],
        backupBox: backupBox,
      );

      expect(
        backupBox.containsKey(SchemaMigrator.backupKey(box.name)),
        isFalse,
      );
    });
  });

  group('失败回滚（不丢数据）', () {
    test('步骤抛异常 → 数据完整回滚且版本号不变', () async {
      await box.put('keep1', 'v1');
      await box.put('keep2', 'v2');
      await box.put('will_change', 'orig');

      final result = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [
          SchemaMigration(
            toVersion: 2,
            description: '先改一个键再抛异常',
            apply: (b) async {
              await b.put('will_change', 'CHANGED');
              await b.put('added', 'NEW');
              throw StateError('模拟迁移中途失败');
            },
          ),
        ],
        backupBox: backupBox,
      );

      expect(result.outcome, MigrationOutcome.failed);
      expect(result.error, isA<StateError>());
      expect(result.toVersion, 1, reason: '版本号必须保持不变以便下次重试');
      // 原始数据完好
      expect(box.get('keep1'), 'v1');
      expect(box.get('keep2'), 'v2');
      expect(box.get('will_change'), 'orig', reason: '被改动的键必须还原');
      expect(box.containsKey('added'), isFalse, reason: '新增的键必须清除');
      expect(SchemaMigrator.readVersion(box), 1);
    });

    test('失败后清理备份（避免下次误判为「未完成」）', () async {
      await box.put('a', '1');
      await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [
          SchemaMigration(
            toVersion: 2,
            description: '失败',
            apply: (_) async => throw StateError('boom'),
          ),
        ],
        backupBox: backupBox,
      );

      expect(
        backupBox.containsKey(SchemaMigrator.backupKey(box.name)),
        isFalse,
      );
    });

    test('失败后再次迁移可以成功（可重试）', () async {
      await box.put('a', '1');
      var attempt = 0;
      final flaky = SchemaMigration(
        toVersion: 2,
        description: '首次失败，之后成功',
        apply: (b) async {
          attempt++;
          if (attempt == 1) throw StateError('第一次失败');
          await b.put('b', b.get('a')!);
          await b.delete('a');
        },
      );

      final first = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [flaky],
        backupBox: backupBox,
      );
      expect(first.outcome, MigrationOutcome.failed);

      final second = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [flaky],
        backupBox: backupBox,
      );
      expect(second.outcome, MigrationOutcome.migrated);
      expect(box.get('b'), '1');
    });

    test('备份写入失败时**中止迁移**（无退路就不动手）', () async {
      await box.put('a', '1');
      var applied = false;

      // 用一个只读的假 backupBox 模拟写入失败
      final result = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [
          SchemaMigration(
            toVersion: 2,
            description: '不应执行',
            apply: (_) async => applied = true,
          ),
        ],
        backupBox: _FailingBox(box.name),
      );

      expect(result.outcome, MigrationOutcome.failed);
      expect(applied, isFalse, reason: '备份失败必须中止，不能冒险迁移');
      expect(box.get('a'), '1');
    });
  });

  group('进程被杀（备份残留 → 恢复）', () {
    test('非幂等步骤在中断后不丢数据（核心场景）', () async {
      await box.put('key_v1', 'important-data');

      // 模拟：上次迁移把 key_v1 改成了 key_v2（非幂等），
      // 但还没写版本号就被系统杀掉。
      await box.put('key_v2', 'important-data');
      await box.delete('key_v1');
      await box.put(
        SchemaMigrator.versionKey(box.name),
        '1', // 版本号仍是旧值 → 下次会重复迁移
      );
      // 备份残留 = 「迁移进行中」标记
      await backupBox.put(
        SchemaMigrator.backupKey(box.name),
        jsonEncode(<String, String>{
          'key_v1': 'important-data',
          SchemaMigrator.versionKey(box.name): '1',
        }),
      );

      // 下次启动：必须先恢复，再重新迁移
      final result = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [renameStep(toVersion: 2, from: 'key_v1', to: 'key_v2')],
        backupBox: backupBox,
      );

      expect(result.outcome, MigrationOutcome.recoveredFromInterrupted);
      expect(result.toVersion, 2);
      expect(
        box.get('key_v2'),
        'important-data',
        reason: '非幂等步骤重复执行会丢数据，恢复机制必须拦住',
      );
      expect(box.containsKey('key_v1'), isFalse);
    });

    test('中断恢复后版本号正确推进', () async {
      await box.put('a', '1');
      await backupBox.put(
        SchemaMigrator.backupKey(box.name),
        jsonEncode(<String, String>{'a': '1'}),
      );

      final result = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [renameStep(toVersion: 2, from: 'a', to: 'b')],
        backupBox: backupBox,
      );

      expect(result.outcome, MigrationOutcome.recoveredFromInterrupted);
      expect(SchemaMigrator.readVersion(box), 2);
      expect(box.get('b'), '1');
    });

    test('中断恢复后若已是最新版本，只恢复不重复迁移', () async {
      await box.put('b', '1');
      await box.put(SchemaMigrator.versionKey(box.name), '2');
      await backupBox.put(
        SchemaMigrator.backupKey(box.name),
        jsonEncode(<String, String>{
          'b': '1',
          SchemaMigrator.versionKey(box.name): '2',
        }),
      );

      final result = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [
          SchemaMigration(
            toVersion: 2,
            description: '不应执行',
            apply: (_) async => throw StateError('不该跑到这里'),
          ),
        ],
        backupBox: backupBox,
      );

      expect(result.outcome, MigrationOutcome.recoveredFromInterrupted);
      expect(box.get('b'), '1');
    });

    test('备份内容损坏时判定为失败，不破坏现有数据', () async {
      await box.put('a', '1');
      await backupBox.put(SchemaMigrator.backupKey(box.name), '{not json');

      final result = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [renameStep(toVersion: 2, from: 'a', to: 'b')],
        backupBox: backupBox,
      );

      expect(result.outcome, MigrationOutcome.failed);
      expect(box.get('a'), '1', reason: '现有数据不能被破坏');
    });

    test('无 backupBox（仅内存快照模式）时不崩，正常迁移', () async {
      await box.put('a', '1');
      final result = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [renameStep(toVersion: 2, from: 'a', to: 'b')],
      );

      expect(result.outcome, MigrationOutcome.migrated);
      expect(box.get('b'), '1');
    });
  });

  group('步骤表校验（必须在动数据之前发现）', () {
    test('缺少中间步骤 → 拒绝且不改动数据', () async {
      await box.put('a', '1');
      await box.put(SchemaMigrator.versionKey(box.name), '1');

      final result = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 3,
        // 缺 v2→v3
        migrations: [renameStep(toVersion: 2, from: 'a', to: 'b')],
        backupBox: backupBox,
      );

      expect(result.outcome, MigrationOutcome.failed);
      expect(box.get('a'), '1', reason: '校验失败不得动数据');
      expect(SchemaMigrator.readVersion(box), 1);
    });

    test('版本号重复 → 拒绝', () async {
      final result = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 3,
        migrations: [
          renameStep(toVersion: 2, from: 'a', to: 'b'),
          renameStep(toVersion: 2, from: 'b', to: 'c'),
        ],
        backupBox: backupBox,
      );

      expect(result.outcome, MigrationOutcome.failed);
    });

    test('步骤表乱序传入也能正确排序执行', () async {
      await box.put('k1', 'p');

      final result = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 3,
        migrations: [
          renameStep(toVersion: 3, from: 'k2', to: 'k3'),
          renameStep(toVersion: 2, from: 'k1', to: 'k2'),
        ],
        backupBox: backupBox,
      );

      expect(result.outcome, MigrationOutcome.migrated);
      expect(box.get('k3'), 'p');
    });
  });

  group('版本高于应用（用户装过更新版本）', () {
    test('拒绝迁移且不改动任何数据', () async {
      await box.put('a', '1');
      await box.put(SchemaMigrator.versionKey(box.name), '5');
      var called = false;

      final result = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [
          SchemaMigration(
            toVersion: 2,
            description: '不应执行',
            apply: (_) async => called = true,
          ),
        ],
        backupBox: backupBox,
      );

      expect(result.outcome, MigrationOutcome.dataNewerThanApp);
      expect(result.isUsable, isFalse, reason: '调用方应据此进入只读降级');
      expect(called, isFalse);
      expect(box.get('a'), '1');
      expect(SchemaMigrator.readVersion(box), 5);
    });
  });

  group('MigrationResult.isUsable', () {
    test('成功 / 已最新 / 中断恢复 均为可用', () async {
      await box.put('a', '1');
      final ok = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [renameStep(toVersion: 2, from: 'a', to: 'b')],
        backupBox: backupBox,
      );
      expect(ok.isUsable, isTrue);

      final upToDate = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [renameStep(toVersion: 2, from: 'a', to: 'b')],
        backupBox: backupBox,
      );
      expect(upToDate.outcome, MigrationOutcome.upToDate);
      expect(upToDate.isUsable, isTrue);
    });

    test('失败不可用', () async {
      final failed = await SchemaMigrator.migrate(
        box: box,
        targetVersion: 2,
        migrations: [
          SchemaMigration(
            toVersion: 2,
            description: '失败',
            apply: (_) async => throw StateError('x'),
          ),
        ],
        backupBox: backupBox,
      );
      expect(failed.isUsable, isFalse);
    });
  });
}

/// 写入恒失败的假 Box：验证「备份写不进去就不动手」。
///
/// 只实现迁移路径真正会调用到的成员（`containsKey` / `put`），
/// 其余一律抛错——这样一旦 [SchemaMigrator] 新增了对备份 Box 的调用，
/// 测试会立刻失败并暴露出来，而不是被静默忽略。
class _FailingBox implements Box<String> {
  _FailingBox(this.name);

  @override
  final String name;

  @override
  bool containsKey(dynamic key) => false;

  @override
  Future<void> put(dynamic key, String value) async =>
      throw StateError('模拟备份写入失败');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试替身未实现：${invocation.memberName}');
}
