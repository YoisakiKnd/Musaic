import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/features/player/domain/queue_logic.dart';

void main() {
  group('nextIndex', () {
    test('顺序模式：中间正常前进', () {
      final r = QueueLogic.nextIndex(
        currentIndex: 1,
        length: 4,
        mode: PlayMode.sequential,
        shuffleOn: false,
      );
      expect(r!.index, 2);
      expect(r.wrapped, isFalse);
    });

    test('顺序模式：末尾返回 null 停止', () {
      final r = QueueLogic.nextIndex(
        currentIndex: 3,
        length: 4,
        mode: PlayMode.sequential,
        shuffleOn: false,
      );
      expect(r, isNull);
    });

    test('列表循环：末尾回零并标记 wrapped', () {
      final r = QueueLogic.nextIndex(
        currentIndex: 3,
        length: 4,
        mode: PlayMode.loopAll,
        shuffleOn: false,
      );
      expect(r!.index, 0);
      expect(r.wrapped, isTrue);
    });

    test('单曲循环：永远停留当前曲', () {
      final r = QueueLogic.nextIndex(
        currentIndex: 2,
        length: 4,
        mode: PlayMode.loopOne,
        shuffleOn: true,
        shuffleOrder: [0, 1, 2, 3],
      );
      expect(r!.index, 2);
    });

    test('随机模式：按洗牌序列前进', () {
      final order = [2, 0, 3, 1];
      expect(
        QueueLogic.nextIndex(
          currentIndex: 2,
          length: 4,
          mode: PlayMode.sequential,
          shuffleOn: true,
          shuffleOrder: order,
        )!.index,
        0,
      );
    });

    test('随机模式一轮播完：顺序停止 / 循环回首轮首并 wrapped', () {
      final order = [2, 0, 3, 1];
      final stop = QueueLogic.nextIndex(
        currentIndex: 1,
        length: 4,
        mode: PlayMode.sequential,
        shuffleOn: true,
        shuffleOrder: order,
      );
      expect(stop, isNull);

      final loop = QueueLogic.nextIndex(
        currentIndex: 1,
        length: 4,
        mode: PlayMode.loopAll,
        shuffleOn: true,
        shuffleOrder: order,
      );
      expect(loop!.index, order.first);
      expect(loop.wrapped, isTrue);
    });

    test('空队列停止', () {
      expect(
        QueueLogic.nextIndex(
          currentIndex: -1,
          length: 0,
          mode: PlayMode.loopAll,
          shuffleOn: false,
        ),
        isNull,
      );
    });
  });

  group('previousIndex', () {
    test('顺序模式：开头保持开头', () {
      final r = QueueLogic.previousIndex(
        currentIndex: 0,
        length: 4,
        mode: PlayMode.sequential,
        shuffleOn: false,
      );
      expect(r!.index, 0);
    });

    test('列表循环：开头跳到末尾', () {
      final r = QueueLogic.previousIndex(
        currentIndex: 0,
        length: 4,
        mode: PlayMode.loopAll,
        shuffleOn: false,
      );
      expect(r!.index, 3);
      expect(r.wrapped, isTrue);
    });

    test('随机模式按洗牌序列后退', () {
      const order = [2, 0, 3, 1];
      expect(
        QueueLogic.previousIndex(
          currentIndex: 0,
          length: 4,
          mode: PlayMode.sequential,
          shuffleOn: true,
          shuffleOrder: order,
        )!.index,
        2,
      );
    });
  });

  group('上一首超 3 秒先回开头', () {
    test('>3s 返回 true', () {
      expect(
        QueueLogic.shouldRestartOnPrevious(
          position: const Duration(seconds: 3, milliseconds: 1),
        ),
        isTrue,
      );
    });

    test('=3s 与 <3s 返回 false', () {
      expect(
        QueueLogic.shouldRestartOnPrevious(
            position: const Duration(seconds: 3)),
        isFalse,
      );
      expect(
        QueueLogic.shouldRestartOnPrevious(position: Duration.zero),
        isFalse,
      );
    });

    test('阈值可自定义', () {
      expect(
        QueueLogic.shouldRestartOnPrevious(
          position: const Duration(seconds: 5),
          threshold: const Duration(seconds: 10),
        ),
        isFalse,
      );
    });
  });

  group('shuffledOrder', () {
    test('是完整排列（无重复无遗漏）', () {
      final order = QueueLogic.shuffledOrder(50, random: Random(7));
      expect(order.toSet().length, 50);
      expect(order.reduce((a, b) => a + b), 50 * 49 ~/ 2);
    });

    test('同一种子结果确定', () {
      expect(
        QueueLogic.shuffledOrder(20, random: Random(42)),
        QueueLogic.shuffledOrder(20, random: Random(42)),
      );
    });

    test('长度为 0/1 安全', () {
      expect(QueueLogic.shuffledOrder(0), isEmpty);
      expect(QueueLogic.shuffledOrder(1), [0]);
    });
  });

  test('定时关闭剩余时间格式化', () {
    expect(
      QueueLogic.formatSleepRemaining(const Duration(minutes: 14, seconds: 5)),
      '14:05',
    );
    expect(
      QueueLogic.formatSleepRemaining(const Duration(hours: 1)),
      '1:00:00',
    );
  });
}
