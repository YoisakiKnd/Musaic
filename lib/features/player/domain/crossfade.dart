/// 交叉淡入淡出（改进计划 N4）。
///
/// ## 为什么需要双播放器
///
/// just_audio **没有原生 crossfade**（只有 `setVolume`）。真正的交叉淡入
/// 需要两路音频同时出声、音量反向斜坡，因此必须持有两个 [AudioPlayer]。
///
/// ## 为什么把算法抽成纯逻辑
///
/// 音量斜坡的听感必须真机验证，但**算法本身是可确定的**：
/// 给定「当前曲剩余时长、淡入淡出时长、是否正在淡出」，每帧两个播放器的
/// 音量是多少。把这段抽出来可完整单测，不依赖音频栈——
/// 于是即使真机环境受限，核心逻辑仍被验证。
///
/// ## 等功率斜坡（而非线性）
///
/// 线性斜坡在交叉点会有约 -3dB 的能量凹陷（两路各 0.5 相加，感知音量下降），
/// 听感上像「中间突然轻了一下」。等功率（equal-power）用余弦/正弦曲线
/// 让两路能量和恒定，是交叉淡入的标准做法。
library;

import 'dart:math' as math;

/// 一次交叉淡入的进度与目标音量。
class CrossfadeLevels {
  const CrossfadeLevels({
    required this.outgoingVolume,
    required this.incomingVolume,
  });

  /// 即将结束那一路的音量（1.0 → 0.0）。
  final double outgoingVolume;

  /// 即将开始那一路的音量（0.0 → 1.0）。
  final double incomingVolume;

  bool get isComplete => outgoingVolume <= 0.0;
}

abstract final class Crossfade {
  /// 交叉淡入的默认时长。
  static const Duration defaultDuration = Duration(seconds: 4);

  /// 允许的时长范围（0 = 关闭）。
  static const Duration minDuration = Duration.zero;
  static const Duration maxDuration = Duration(seconds: 12);

  /// 计算淡入进度 `t ∈ [0, 1]`。
  ///
  /// [remaining] 为当前曲目剩余时长；[duration] 为交叉淡入总时长。
  /// 剩余时间大于淡入时长时返回 0（还没开始）；
  /// 剩余时间 ≤ 0（已播完）时返回 1（淡入应已完成）。
  static double progress({
    required Duration remaining,
    required Duration duration,
  }) {
    if (duration <= Duration.zero) return 1.0; // 关闭：视为瞬间完成
    final remainingMs = remaining.inMilliseconds;
    if (remainingMs <= 0) return 1.0;
    final durationMs = duration.inMilliseconds;
    if (remainingMs >= durationMs) return 0.0;
    return 1.0 - (remainingMs / durationMs);
  }

  /// 按等功率曲线计算两路音量。
  ///
  /// `t = 0` → 旧曲 1.0 / 新曲 0.0；`t = 1` → 旧曲 0.0 / 新曲 1.0。
  /// 使用 `cos`/`sin` 而非线性：线性在交叉点会有可感知的音量凹陷。
  static CrossfadeLevels levelsAt(double t) {
    final clamped = t.clamp(0.0, 1.0);
    // 端点直接返回精确值：`cos(π/2)` 浮点结果是 6.1e-17 而非 0，
    // 会让「旧曲是否已完全静音」的判断失败，且播放器上残留极小音量
    // 可能在部分平台被视为仍在出声（影响音频焦点释放）。
    if (clamped <= 0.0) {
      return const CrossfadeLevels(outgoingVolume: 1.0, incomingVolume: 0.0);
    }
    if (clamped >= 1.0) {
      return const CrossfadeLevels(outgoingVolume: 0.0, incomingVolume: 1.0);
    }
    // 0 → π/2 的象限，cos 从 1 降到 0、sin 从 0 升到 1，平方和恒为 1
    final angle = clamped * (math.pi / 2);
    return CrossfadeLevels(
      outgoingVolume: math.cos(angle),
      incomingVolume: math.sin(angle),
    );
  }

  /// 便捷方法：由剩余时长直接算出两路音量。
  ///
  /// [baseVolume] 为用户设定的音量——淡入淡出作用于**相对**音量，
  /// 不应覆盖用户的音量设置。
  static CrossfadeLevels levelsFor({
    required Duration remaining,
    required Duration duration,
    double baseVolume = 1.0,
  }) {
    final levels = levelsAt(progress(remaining: remaining, duration: duration));
    final base = baseVolume.clamp(0.0, 1.0);
    return CrossfadeLevels(
      outgoingVolume: levels.outgoingVolume * base,
      incomingVolume: levels.incomingVolume * base,
    );
  }

  /// 是否应在此刻启动下一首（用于触发预加载/播放）。
  ///
  /// 提前量取淡入时长本身：需要在淡入开始时就让新曲出声。
  static bool shouldStart({
    required Duration remaining,
    required Duration duration,
  }) {
    if (duration <= Duration.zero) return false;
    return remaining <= duration && remaining > Duration.zero;
  }
}
