import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/utils/cover_cache.dart';

/// 封面缓存目录的单一事实源 + 存储占用格式化（日常可用性计划 D10）。
///
/// 这里曾出现真实缺陷：缓存**写入**目录与应用支持目录对齐了，
/// 但设置页的清理入口仍指向临时目录，导致「已清除」是假的。
/// 根因是两处各自计算路径——现已收敛到 `core/utils/cover_cache.dart`。
/// 本测试断言该单一来源存在且语义正确（不依赖平台通道）。
void main() {
  group('封面缓存目录单一事实源', () {
    test('目录名常量唯一且非空', () {
      expect(coverCacheDirName, 'musaic_covers');
    });

    test('暴露目录 / 统计 / 清理三个入口（调用方无需自行拼路径）', () {
      // 存在性检查：这三者必须同源导出，否则又会各自计算路径
      expect(coverCacheDirectory, isA<Function>());
      expect(coverCacheBytes, isA<Function>());
      expect(clearCoverCache, isA<Function>());
    });
  });

  group('formatBytes', () {
    test('字节级', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('KB 级（保留一位小数）', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024 - 1), '1024.0 KB');
    });

    test('MB 级', () {
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(100 * 1024 * 1024), '100.0 MB');
      expect(formatBytes(1536 * 1024), '1.5 MB');
    });

    test('极大值不抛异常', () {
      expect(() => formatBytes(1 << 40), returnsNormally);
      expect(formatBytes(1 << 40), contains('MB'));
    });

    test('负数归零（防御性，避免显示 -1 B）', () {
      expect(formatBytes(-1), '0 B');
    });
  });
}
