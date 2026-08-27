import 'dart:math';

import '../../../core/model/track.dart';

/// 播放模式：顺序播放 / 列表循环 / 单曲循环；随机通过洗牌序列叠加实现。
enum PlayMode { sequential, loopAll, loopOne }

class QueueAdvance {
  const QueueAdvance(this.index, {this.wrapped = false});

  /// 下一曲下标。
  final int index;

  /// 是否越过了队列末尾（随机模式下调用方借此重新洗牌）。
  final bool wrapped;
}

abstract final class QueueLogic {
  /// 「上一首超 3 秒先回开头」（Mei 行为对齐）。
  static bool shouldRestartOnPrevious({
    required Duration position,
    Duration threshold = const Duration(seconds: 3),
  }) =>
      position > threshold;

  /// 计算下一曲；返回 null 表示停止播放。
  ///
  /// [shuffleOrder] 为当前洗牌序列（长度须等于 [length]）。
  static QueueAdvance? nextIndex({
    required int currentIndex,
    required int length,
    required PlayMode mode,
    required bool shuffleOn,
    List<int>? shuffleOrder,
  }) {
    assert(length >= 0);
    if (length == 0) return null;
    if (mode == PlayMode.loopOne) return QueueAdvance(currentIndex);

    if (shuffleOn) {
      final order = shuffleOrder ?? List<int>.generate(length, (i) => i);
      assert(order.length == length, 'shuffleOrder length mismatch');
      final pos = currentIndex >= 0 && currentIndex < length
          ? order.indexOf(currentIndex)
          : -1;
      if (pos < 0 || pos == length - 1) {
        switch (mode) {
          case PlayMode.sequential:
            return null; // 一轮播完即停
          case PlayMode.loopAll:
            return QueueAdvance(order.first, wrapped: true);
          case PlayMode.loopOne:
            return QueueAdvance(currentIndex);
        }
      }
      return QueueAdvance(order[pos + 1]);
    }

    if (currentIndex + 1 < length) {
      return QueueAdvance(currentIndex + 1);
    }
    switch (mode) {
      case PlayMode.sequential:
        return null;
      case PlayMode.loopAll:
        return const QueueAdvance(0, wrapped: true);
      case PlayMode.loopOne:
        return QueueAdvance(currentIndex.clamp(0, length - 1));
    }
  }

  /// 计算上一曲（不含「回开头」规则，那由调用方先判断）；null 表示停止。
  static QueueAdvance? previousIndex({
    required int currentIndex,
    required int length,
    required PlayMode mode,
    required bool shuffleOn,
    List<int>? shuffleOrder,
  }) {
    if (length == 0) return null;
    if (mode == PlayMode.loopOne) return QueueAdvance(currentIndex);

    if (shuffleOn) {
      final order = shuffleOrder ?? List<int>.generate(length, (i) => i);
      final pos = currentIndex >= 0 && currentIndex < length
          ? order.indexOf(currentIndex)
          : -1;
      if (pos <= 0) {
        switch (mode) {
          case PlayMode.sequential:
            return pos == 0 ? QueueAdvance(order.first) : null;
          case PlayMode.loopAll:
            return QueueAdvance(order.last, wrapped: true);
          case PlayMode.loopOne:
            return QueueAdvance(currentIndex);
        }
      }
      return QueueAdvance(order[pos - 1]);
    }

    if (currentIndex > 0) {
      return QueueAdvance(currentIndex - 1);
    }
    switch (mode) {
      case PlayMode.sequential:
        return currentIndex == 0 ? const QueueAdvance(0) : null;
      case PlayMode.loopAll:
        return QueueAdvance(length - 1, wrapped: true);
      case PlayMode.loopOne:
        return const QueueAdvance(0);
    }
  }

  /// Fisher–Yates 洗牌序列；[random] 注入便于测试确定性。
  static List<int> shuffledOrder(int length, {Random? random}) {
    final order = List<int>.generate(length, (i) => i);
    final rng = random ?? Random();
    for (var i = order.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final tmp = order[i];
      order[i] = order[j];
      order[j] = tmp;
    }
    return order;
  }

  /// 定时关闭剩余时长展示文案，如 `14:59`。
  static String formatSleepRemaining(Duration remaining) {
    final minutes = remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = remaining.inHours;
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  // ---------- 队列变更纯函数（供 PlayerNotifier 委托，可单测） ----------

  /// 移除 [index] 处曲目，返回新队列 / 新当前下标 / 是否移除的正是当前曲。
  ///
  /// 移除当前曲时，[currentIndex] 指向「顺延到位」的曲目（末尾则回退一格），
  /// 调用方据此决定是否续播；队列被移空时返回 -1。
  static ({
    List<Track> queue,
    int currentIndex,
    bool removedCurrent,
  }) removeTrackAt({
    required List<Track> queue,
    required int index,
    required int currentIndex,
  }) {
    if (index < 0 || index >= queue.length) {
      return (queue: queue, currentIndex: currentIndex, removedCurrent: false);
    }
    final next = [...queue]..removeAt(index);
    if (next.isEmpty) {
      return (queue: next, currentIndex: -1, removedCurrent: index == currentIndex);
    }
    final removedCurrent = index == currentIndex;
    final newCurrent = removedCurrent
        ? index.clamp(0, next.length - 1)
        : (index < currentIndex ? currentIndex - 1 : currentIndex);
    return (queue: next, currentIndex: newCurrent, removedCurrent: removedCurrent);
  }

  /// 队列内移动（[newIndex] 为移除后语义，即 ReorderableListView.onReorderItem）。
  /// 当前曲目以 key 追踪跟随自身位置。
  static ({List<Track> queue, int currentIndex}) moveTrack({
    required List<Track> queue,
    required int oldIndex,
    required int newIndex,
    required int currentIndex,
  }) {
    if (oldIndex < 0 || oldIndex >= queue.length) {
      return (queue: queue, currentIndex: currentIndex);
    }
    final target = newIndex.clamp(0, queue.length - 1);
    if (target == oldIndex) {
      return (queue: queue, currentIndex: currentIndex);
    }
    final currentKey = currentIndex >= 0 && currentIndex < queue.length
        ? queue[currentIndex].key
        : null;
    final next = [...queue];
    final item = next.removeAt(oldIndex);
    next.insert(target, item);
    final newCurrent = currentKey == null
        ? currentIndex
        : next.indexWhere((t) => t.key == currentKey);
    return (queue: next, currentIndex: newCurrent);
  }

  /// 把 [track] 插入当前曲之后作为「下一首播放」；已在队列中则先去重再插入。
  static ({List<Track> queue, int currentIndex}) insertAsNext({
    required List<Track> queue,
    required Track track,
    required int currentIndex,
  }) {
    final next = [...queue];
    var current = currentIndex;
    final existing = next.indexWhere((t) => t.key == track.key);
    if (existing >= 0) {
      if (current >= 0 && existing < current) current--;
      next.removeAt(existing);
    }
    final at = (current + 1).clamp(0, next.length);
    next.insert(at, track);
    return (queue: next, currentIndex: current);
  }
}
