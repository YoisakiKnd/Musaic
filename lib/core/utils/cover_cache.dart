/// 本地封面缓存的**单一事实源**（日常可用性计划 D10）。
///
/// 背景：这里曾出现一个真实缺陷——缓存**写入**目录从临时目录改成了
/// 应用支持目录（避免系统清理临时目录导致已扫描曲目的封面失效），
/// 但设置页的「清除封面缓存」仍指向临时目录。
/// 结果按钮点了显示「已清除」，实际什么也没清，占用也统计不到。
///
/// 根因不是「忘了改」，而是**两处各自计算路径**。因此把目录、统计、
/// 清理全部收敛到本模块，调用方只依赖这里，结构上就不可能再漂移。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 封面缓存目录名。
const String coverCacheDirName = 'musaic_covers';

/// 封面缓存目录。
///
/// 放在**应用支持目录**而非临时目录：系统可随时清理 temp，
/// 会导致已扫描曲目的封面 URL 失效（列表封面集体变占位图）。
/// 支持目录由应用负责清理，配合内容哈希命名可复用已有文件。
Future<Directory> coverCacheDirectory() async {
  final base = await getApplicationSupportDirectory();
  return Directory(p.join(base.path, coverCacheDirName));
}

/// 统计封面缓存占用（字节）。目录不存在或读取失败返回 0。
///
/// 读取失败不抛异常：占用统计是辅助信息，不该让设置页崩掉。
Future<int> coverCacheBytes() async {
  try {
    final dir = await coverCacheDirectory();
    if (!dir.existsSync()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  } catch (_) {
    return 0;
  }
}

/// 清空封面缓存；返回是否真的删除了内容（目录不存在返回 false）。
Future<bool> clearCoverCache() async {
  try {
    final dir = await coverCacheDirectory();
    if (!dir.existsSync()) return false;
    await dir.delete(recursive: true);
    return true;
  } catch (_) {
    return false;
  }
}

/// 人类可读的字节数（设置页展示用）。
///
/// 纯函数，便于单测。
String formatBytes(int bytes) {
  if (bytes < 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
