import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/features/player/domain/crossfade.dart';

/// 交叉淡入算法（改进计划 N4）。
///
/// 听感需真机验证，但**算法是确定的**，因此这里穷尽边界：
/// 等功率曲线、音量不越过用户设定、关闭时不动音量、进度边界。
void main() {
  group('progress 进度计算', () {
    test('剩余时间大于淡入时长 → 进度 0（尚未开始）', () {
      expect(
        Crossfade.progress(
          remaining: const Duration(seconds: 30),
          duration: const Duration(seconds: 4),
        ),
        0.0,
      );
    });

    test('剩余时间恰好等于淡入时长 → 进度 0（刚开始）', () {
      expect(
        Crossfade.progress(
          remaining: const Duration(seconds: 4),
          duration: const Duration(seconds: 4),
        ),
        0.0,
      );
    });

    test('剩余一半 → 进度 0.5', () {
      expect(
        Crossfade.progress(
          remaining: const Duration(seconds: 2),
          duration: const Duration(seconds: 4),
        ),
        closeTo(0.5, 1e-9),
      );
    });

    test('剩余 0 → 进度 1（应已完成）', () {
      expect(
        Crossfade.progress(
          remaining: Duration.zero,
          duration: const Duration(seconds: 4),
        ),
        1.0,
      );
    });

    test('剩余为负（已播过头）→ 进度 1，不出现负值', () {
      expect(
        Crossfade.progress(
          remaining: const Duration(seconds: -5),
          duration: const Duration(seconds: 4),
        ),
        1.0,
      );
    });

    test('时长为 0（功能关闭）→ 进度 1（瞬间完成，不参与渐变）', () {
      expect(
        Crossfade.progress(
          remaining: const Duration(seconds: 10),
          duration: Duration.zero,
        ),
        1.0,
      );
    });
  });

  group('levelsAt 等功率曲线', () {
    test('起点：旧曲满、新曲静音', () {
      final levels = Crossfade.levelsAt(0);
      expect(levels.outgoingVolume, closeTo(1.0, 1e-9));
      expect(levels.incomingVolume, closeTo(0.0, 1e-9));
    });

    test('终点：旧曲静音、新曲满', () {
      final levels = Crossfade.levelsAt(1);
      expect(levels.outgoingVolume, closeTo(0.0, 1e-9));
      expect(levels.incomingVolume, closeTo(1.0, 1e-9));
      expect(levels.isComplete, isTrue);
    });

    test('中点：两路各约 0.707（等功率，而非线性 0.5）', () {
      final levels = Crossfade.levelsAt(0.5);
      expect(levels.outgoingVolume, closeTo(math.sqrt1_2, 1e-9));
      expect(levels.incomingVolume, closeTo(math.sqrt1_2, 1e-9));
      // 关键：线性斜坡此处会是 0.5，导致能量和下降 → 听感凹陷
      expect(levels.outgoingVolume, greaterThan(0.5));
    });

    test('全程能量和恒定（等功率的核心性质）', () {
      for (var i = 0; i <= 20; i++) {
        final levels = Crossfade.levelsAt(i / 20);
        final power =
            levels.outgoingVolume * levels.outgoingVolume +
            levels.incomingVolume * levels.incomingVolume;
        expect(power, closeTo(1.0, 1e-9), reason: 't=${i / 20} 处能量和不恒定会导致音量凹陷');
      }
    });

    test('单调性：旧曲递减、新曲递增', () {
      var prevOut = 2.0;
      var prevIn = -1.0;
      for (var i = 0; i <= 20; i++) {
        final levels = Crossfade.levelsAt(i / 20);
        expect(levels.outgoingVolume, lessThan(prevOut));
        expect(levels.incomingVolume, greaterThan(prevIn));
        prevOut = levels.outgoingVolume;
        prevIn = levels.incomingVolume;
      }
    });

    test('端点返回**精确** 0 / 1（浮点边界）', () {
      // cos(π/2) 的浮点结果是 6.1e-17 而非 0。若不做端点特判，
      // 「旧曲已静音」判断会失败，且播放器上残留极小音量。
      expect(Crossfade.levelsAt(0).incomingVolume, 0.0);
      expect(Crossfade.levelsAt(1).outgoingVolume, 0.0);
      expect(Crossfade.levelsAt(1).incomingVolume, 1.0);
      expect(Crossfade.levelsAt(0).outgoingVolume, 1.0);
    });

    test('越界输入被钳制（不产生 >1 或 <0 的音量）', () {
      final below = Crossfade.levelsAt(-0.5);
      expect(below.outgoingVolume, closeTo(1.0, 1e-9));
      expect(below.incomingVolume, closeTo(0.0, 1e-9));

      final above = Crossfade.levelsAt(1.5);
      expect(above.outgoingVolume, closeTo(0.0, 1e-9));
      expect(above.incomingVolume, closeTo(1.0, 1e-9));
    });
  });

  group('levelsFor 与用户音量', () {
    test('作用于相对音量：不覆盖用户的音量设置', () {
      final levels = Crossfade.levelsFor(
        remaining: const Duration(seconds: 2),
        duration: const Duration(seconds: 4),
        baseVolume: 0.5,
      );
      // 中点各 0.707 × 0.5 ≈ 0.354
      expect(levels.outgoingVolume, closeTo(math.sqrt1_2 * 0.5, 1e-9));
      expect(levels.incomingVolume, closeTo(math.sqrt1_2 * 0.5, 1e-9));
    });

    test('用户音量 0（静音）时两路都为 0', () {
      final levels = Crossfade.levelsFor(
        remaining: const Duration(seconds: 2),
        duration: const Duration(seconds: 4),
        baseVolume: 0,
      );
      expect(levels.outgoingVolume, 0.0);
      expect(levels.incomingVolume, 0.0);
    });

    test('用户音量越界被钳制到 [0,1]', () {
      final high = Crossfade.levelsFor(
        remaining: Duration.zero,
        duration: const Duration(seconds: 4),
        baseVolume: 5.0,
      );
      expect(high.incomingVolume, lessThanOrEqualTo(1.0));

      final low = Crossfade.levelsFor(
        remaining: Duration.zero,
        duration: const Duration(seconds: 4),
        baseVolume: -1.0,
      );
      expect(low.incomingVolume, 0.0);
    });

    test('默认 baseVolume 为 1（不影响未设置音量的场景）', () {
      final levels = Crossfade.levelsFor(
        remaining: Duration.zero,
        duration: const Duration(seconds: 4),
      );
      expect(levels.incomingVolume, closeTo(1.0, 1e-9));
    });
  });

  group('shouldStart 触发时机', () {
    test('剩余时间进入淡入窗口 → 应启动', () {
      expect(
        Crossfade.shouldStart(
          remaining: const Duration(seconds: 3),
          duration: const Duration(seconds: 4),
        ),
        isTrue,
      );
    });

    test('剩余时间仍在窗口外 → 不启动', () {
      expect(
        Crossfade.shouldStart(
          remaining: const Duration(seconds: 10),
          duration: const Duration(seconds: 4),
        ),
        isFalse,
      );
    });

    test('恰好等于窗口 → 启动（边界包含）', () {
      expect(
        Crossfade.shouldStart(
          remaining: const Duration(seconds: 4),
          duration: const Duration(seconds: 4),
        ),
        isTrue,
      );
    });

    test('已播完（剩余 0）→ 不再启动（避免重复触发）', () {
      expect(
        Crossfade.shouldStart(
          remaining: Duration.zero,
          duration: const Duration(seconds: 4),
        ),
        isFalse,
      );
    });

    test('功能关闭（时长 0）→ 永不启动', () {
      expect(
        Crossfade.shouldStart(
          remaining: const Duration(seconds: 1),
          duration: Duration.zero,
        ),
        isFalse,
      );
    });
  });

  group('时长范围常量', () {
    test('默认 4 秒，范围 0–12 秒', () {
      expect(Crossfade.defaultDuration, const Duration(seconds: 4));
      expect(Crossfade.minDuration, Duration.zero);
      expect(Crossfade.maxDuration, const Duration(seconds: 12));
    });

    test('默认值落在允许范围内', () {
      expect(Crossfade.defaultDuration >= Crossfade.minDuration, isTrue);
      expect(Crossfade.defaultDuration <= Crossfade.maxDuration, isTrue);
    });
  });
}
