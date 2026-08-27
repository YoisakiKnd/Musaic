import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/features/player/domain/queue_logic.dart';

Track _t(String id) =>
    Track(id: id, sourceId: 'netease', title: id, artist: 'a');

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

  group('removeTrackAt', () {
    final queue = [_t('a'), _t('b'), _t('c'), _t('d')];

    test('移除当前曲之前的项：current 前移一位', () {
      final r = QueueLogic.removeTrackAt(
          queue: queue, index: 0, currentIndex: 2);
      expect(r.queue.map((t) => t.id), ['b', 'c', 'd']);
      expect(r.currentIndex, 1); // 原 c(2) → 现 1
      expect(r.removedCurrent, isFalse);
    });

    test('移除当前曲：指向顺延的下一曲，标记 removedCurrent', () {
      final r = QueueLogic.removeTrackAt(
          queue: queue, index: 2, currentIndex: 2);
      expect(r.removedCurrent, isTrue);
      expect(r.currentIndex, 2); // c 被删，d 顺延到 index 2
      expect(r.queue[2].id, 'd');
    });

    test('移除末尾当前曲：current 回退一格', () {
      final r = QueueLogic.removeTrackAt(
          queue: queue, index: 3, currentIndex: 3);
      expect(r.removedCurrent, isTrue);
      expect(r.currentIndex, 2);
    });

    test('移除唯一曲目：队列空、current = -1', () {
      final r = QueueLogic.removeTrackAt(
          queue: [_t('x')], index: 0, currentIndex: 0);
      expect(r.queue, isEmpty);
      expect(r.currentIndex, -1);
    });

    test('越界索引：原样返回且 removedCurrent=false', () {
      final r = QueueLogic.removeTrackAt(
          queue: queue, index: 9, currentIndex: 1);
      expect(identical(r.queue, queue), isTrue);
      expect(r.removedCurrent, isFalse);
    });
  });

  group('moveTrack', () {
    final queue = [_t('a'), _t('b'), _t('c')];

    test('下移非当前曲：当前曲目按 key 追踪', () {
      final r = QueueLogic.moveTrack(
          queue: queue, oldIndex: 0, newIndex: 2, currentIndex: 2);
      expect(r.queue.map((t) => t.id), ['b', 'c', 'a']);
      expect(r.queue[r.currentIndex].id, 'c');
    });

    test('移动当前曲自身：currentIndex 跟随落点', () {
      final r = QueueLogic.moveTrack(
          queue: queue, oldIndex: 0, newIndex: 1, currentIndex: 0);
      expect(r.queue.map((t) => t.id), ['b', 'a', 'c']);
      expect(r.currentIndex, 1);
    });

    test('原地移动 / 越界：不改队列', () {
      final same = QueueLogic.moveTrack(
          queue: queue, oldIndex: 1, newIndex: 1, currentIndex: 0);
      expect(identical(same.queue, queue), isTrue);
      final oob = QueueLogic.moveTrack(
          queue: queue, oldIndex: 5, newIndex: 0, currentIndex: 0);
      expect(identical(oob.queue, queue), isTrue);
    });
  });

  group('insertAsNext', () {
    test('空队列插入（current=-1）落队首，current 保持 -1', () {
      final r = QueueLogic.insertAsNext(
          queue: const [], track: _t('n'), currentIndex: -1);
      expect(r.queue.map((t) => t.id), ['n']);
      expect(r.currentIndex, -1); // 开播决策留给上层
    });

    test('插入到当前曲之后', () {
      final r = QueueLogic.insertAsNext(
          queue: [_t('a'), _t('b')], track: _t('n'), currentIndex: 0);
      expect(r.queue.map((t) => t.id), ['a', 'n', 'b']);
      expect(r.currentIndex, 0);
    });

    test('已在队列前部的曲目：去重移动且 current 不错位', () {
      final r = QueueLogic.insertAsNext(
          queue: [_t('n'), _t('a'), _t('b')],
          track: _t('n'),
          currentIndex: 2);
      // n 从索引 0 移走 → current 2→1；再插到 current+1=2
      expect(r.currentIndex, 1);
      expect(r.queue[r.currentIndex + 1].id, 'n');
    });
  });
}
