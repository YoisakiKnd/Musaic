import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/storage/hive_recovery.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_hive_recovery');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    try {
      await Hive.close();
    } catch (_) {}
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('openBoxSafely 启动容错（迭代计划 §7.5 / B08）', () {
    test('正常路径：直接打开可用 Box', () async {
      final box = await openBoxSafely<String>('recovery_ok', tempDir.path);
      await box.put('k', 'v');
      expect(box.get('k'), 'v');
      await box.close();
    });

    test('损坏 Box：备份原文件后重建空 Box，不阻塞启动', () async {
      // 先写一个正常 Box 再注入损坏数据：
      // openBoxSafely 关闭了 Hive 内置 crashRecovery（静默截断丢数据），
      // 损坏文件会让打开失败，走「备份 → 重建」路径。
      final corrupt = await Hive.openBox<String>('recovery_corrupt');
      await corrupt.put('k', 'v');
      await corrupt.close();

      final boxFile = File('${tempDir.path}/recovery_corrupt.hive');
      expect(boxFile.existsSync(), isTrue);
      await boxFile.writeAsBytes([0x00, 0xFF, 0x13, 0x37, 0x00, 0x01]);

      final box = await openBoxSafely<String>('recovery_corrupt', tempDir.path);
      expect(box.isEmpty, isTrue, reason: '重建后应为空 Box');
      await box.put('fresh', 'ok');
      expect(box.get('fresh'), 'ok');
      await box.close();

      // 损坏数据保留在备份文件中等待恢复
      final backups =
          tempDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.contains('recovery_corrupt.hive.corrupt-'))
              .toList();
      expect(backups, hasLength(1));
    });

    test('残留锁文件：不阻塞正常打开', () async {
      final lockFile = File('${tempDir.path}/recovery_lock.lock');
      lockFile.writeAsBytesSync([0x01]);
      final box = await openBoxSafely<String>('recovery_lock', tempDir.path);
      expect(box.isOpen, isTrue);
      await box.close();
    });
  });
}
