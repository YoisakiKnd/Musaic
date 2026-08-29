import 'dart:async';
import 'dart:io';

import 'package:hive/hive.dart';

/// Hive Box 容错打开（迭代计划 §7.5 启动恢复 / B08）。
///
/// 关闭 Hive 内置的 crashRecovery（它会静默截断损坏帧、无备份地丢数据），
/// 改为按计划语义自管恢复：单个 Box 打开失败时，先把数据文件备份为
/// `.corrupt-<毫秒时间戳>`，再重建空 Box，保证应用永远可以进入首页；
/// 损坏数据保留在备份文件中，等待用户手动恢复或反馈。
/// 重开仍失败（目录级异常）时继续抛出，由调用方决定降级。
Future<Box<E>> openBoxSafely<E>(String name, String baseDir) async {
  final first = await _tryOpenBox<E>(name);
  if (first != null) return first;
  _backupCorruptBoxFile(name, baseDir);
  // Hive 打开失败后的异步清理可能仍持有锁文件，稍作重试
  for (var attempt = 0; attempt < 3; attempt++) {
    final box = await _tryOpenBox<E>(name);
    if (box != null) return box;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('Hive Box「$name」损坏且重建失败（数据已备份为 .corrupt-*）');
}

/// 在受控 zone 中尝试打开 Box。
///
/// Hive 打开失败时其内部 completer 链会把错误二次透传到当前 zone
/// （即使调用方已捕获），这里用 runZonedGuarded 吸收，
/// 保证错误只在返回值中体现，不污染全局异常处理。
Future<Box<E>?> _tryOpenBox<E>(String name) {
  final completer = Completer<Box<E>?>();
  runZonedGuarded(
    () {
      Hive.openBox<E>(name, crashRecovery: false).then(completer.complete);
    },
    (error, stackTrace) {
      if (!completer.isCompleted) completer.complete(null);
    },
  );
  return completer.future;
}

/// 只备份数据文件；`.lock` 留给 Hive 自身的失败清理删除，
/// 抢先改名会让其清理抛出「文件不存在」的异步异常。
void _backupCorruptBoxFile(String name, String baseDir) {
  final file = File('$baseDir/$name.hive');
  if (!file.existsSync()) return;
  final stamp = DateTime.now().millisecondsSinceEpoch;
  try {
    file.renameSync('$baseDir/$name.hive.corrupt-$stamp');
  } catch (_) {
    // 备份失败不阻塞重建：宁可新 Box 可用，也不让首页起不来
  }
}
