import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/features/settings/data/local_music_settings_repository.dart';

/// 本地音乐设置仓库的边界与损坏数据容错（T3 边界异常测试）。
///
/// 该类此前只有间接覆盖（schema 注册表测试会引用 Box 名），
/// 实际读写逻辑没有直接测试。重点在**损坏数据不崩**：
/// Hive 里存的 JSON 可能被旧版本、手动改文件或异常中断写坏，
/// 用户不该因此打不开设置页。
void main() {
  late Directory tempDir;
  late Box<String> box;
  late LocalMusicSettingsRepository repository;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_local_music_test');
    Hive.init(tempDir.path);
    box = await Hive.openBox<String>('local_music_settings_test');
  });

  tearDownAll(() async {
    if (box.isOpen) await box.close();
    await Hive.close();
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  setUp(() async {
    await box.clear();
    repository = LocalMusicSettingsRepository(box: box);
  });

  group('文件夹列表读写', () {
    test('初始为空', () {
      expect(repository.folders, isEmpty);
    });

    test('添加后可读回，且顺序保持', () async {
      await repository.addFolder('/music/a');
      await repository.addFolder('/music/b');

      expect(repository.folders, ['/music/a', '/music/b']);
    });

    test('重复添加同一路径不产生重复项（幂等）', () async {
      await repository.addFolder('/music/a');
      await repository.addFolder('/music/a');
      await repository.addFolder('/music/a');

      expect(repository.folders, ['/music/a']);
    });

    test('添加时 trim，且空串/纯空白被忽略', () async {
      await repository.addFolder('  /music/a  ');
      await repository.addFolder('');
      await repository.addFolder('   ');

      expect(repository.folders, ['/music/a']);
    });

    test('trim 后相同视为重复', () async {
      await repository.addFolder('/music/a');
      await repository.addFolder('  /music/a  ');
      expect(repository.folders, hasLength(1));
    });

    test('移除存在的路径', () async {
      await repository.addFolder('/music/a');
      await repository.addFolder('/music/b');

      await repository.removeFolder('/music/a');

      expect(repository.folders, ['/music/b']);
    });

    test('移除不存在的路径是 no-op（不抛异常）', () async {
      await repository.addFolder('/music/a');

      await expectLater(repository.removeFolder('/music/nope'), completes);
      expect(repository.folders, ['/music/a']);
    });

    test('移除全部后为空', () async {
      await repository.addFolder('/music/a');
      await repository.removeFolder('/music/a');
      expect(repository.folders, isEmpty);
    });
  });

  group('损坏数据容错（关键）', () {
    test('非 JSON 内容返回空列表而非抛异常', () async {
      await box.put('folders', '这不是 JSON');
      expect(repository.folders, isEmpty);
    });

    test('JSON 但类型不对（对象而非数组）返回空列表', () async {
      await box.put('folders', '{"a":1}');
      expect(repository.folders, isEmpty);
    });

    test('数组含非字符串项时只保留字符串项', () async {
      await box.put('folders', '["/a", 123, null, "/b", {"x":1}]');
      expect(repository.folders, ['/a', '/b']);
    });

    test('空数组返回空列表', () async {
      await box.put('folders', '[]');
      expect(repository.folders, isEmpty);
    });

    test('空字符串内容返回空列表', () async {
      await box.put('folders', '');
      expect(repository.folders, isEmpty);
    });

    test('损坏数据后仍可正常添加（自愈）', () async {
      await box.put('folders', '坏数据');

      await repository.addFolder('/music/new');

      expect(repository.folders, ['/music/new']);
    });

    test('超长路径不抛异常', () async {
      final long = '/${'a' * 5000}';
      await expectLater(repository.addFolder(long), completes);
      expect(repository.folders.single, long);
    });

    test('非 ASCII 与含空格路径正确处理', () async {
      await repository.addFolder('/音乐/我的 收藏');
      expect(repository.folders, ['/音乐/我的 收藏']);
    });
  });

  group('自动扫描开关', () {
    test('默认关闭', () {
      expect(repository.autoScanOnStartup, isFalse);
    });

    test('开启后可读回', () async {
      await repository.setAutoScanOnStartup(true);
      expect(repository.autoScanOnStartup, isTrue);
    });

    test('关闭后可读回', () async {
      await repository.setAutoScanOnStartup(true);
      await repository.setAutoScanOnStartup(false);
      expect(repository.autoScanOnStartup, isFalse);
    });

    test('损坏值视为关闭（不抛异常）', () async {
      await box.put('auto_scan', 'maybe');
      expect(repository.autoScanOnStartup, isFalse);
    });
  });

  group('Box 名常量', () {
    test('与 schema 注册表一致（改名会让迁移静默跳过）', () {
      expect(LocalMusicSettingsRepository.boxName, 'local_music_settings');
    });
  });
}
