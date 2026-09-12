import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/features/player/data/resume_repository.dart';
import 'package:musaic/features/player/domain/queue_logic.dart';

/// 断点续播快照边界（迭代计划 B25 / H18）。
///
/// 旧实现的两个问题：
/// 1. `fromJson` 不校验 index，越界时 `track` 恒为 null，快照被静默丢弃；
/// 2. `save` 直接把越界 index 写盘，留下永远无法恢复的记录。
void main() {
  late Directory tempDir;
  late Box<String> box;
  late ResumeRepository repository;

  Track track(String id) =>
      Track(id: id, sourceId: 'netease', title: 't$id', artist: 'a');

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_resume_test');
    Hive.init(tempDir.path);
    box = await Hive.openBox<String>('resume_test');
  });

  tearDownAll(() async {
    await box.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  setUp(() async => box.clear());

  ResumePlayback snapshot({
    required List<Track> queue,
    required int index,
    Duration position = Duration.zero,
  }) => ResumePlayback(
    queue: queue,
    index: index,
    position: position,
    savedAt: DateTime.now(),
  );

  group('save 越界钳制', () {
    test('index 超出队列长度时被钳到末位且可恢复', () async {
      repository = ResumeRepository(box: box);
      await repository.save(
        snapshot(queue: [track('a'), track('b')], index: 99),
      );

      final loaded = repository.load();
      expect(loaded, isNotNull, reason: '越界快照不应变成不可恢复');
      expect(loaded!.index, 1);
      expect(loaded.track?.id, 'b');
    });

    test('负数 index 被钳到 0', () async {
      repository = ResumeRepository(box: box);
      await repository.save(
        snapshot(queue: [track('a'), track('b')], index: -5),
      );

      final loaded = repository.load();
      expect(loaded!.index, 0);
      expect(loaded.track?.id, 'a');
    });

    test('空队列不写入垃圾快照（清空已有记录）', () async {
      repository = ResumeRepository(box: box);
      await repository.save(snapshot(queue: [track('a')], index: 0));
      expect(repository.load(), isNotNull);

      await repository.save(snapshot(queue: const <Track>[], index: 0));
      expect(repository.load(), isNull, reason: '空队列应清空而非留坏记录');
    });
  });

  group('fromJson 容错', () {
    test('手写越界 JSON 也能恢复（旧版本残留数据）', () async {
      repository = ResumeRepository(box: box);
      // 直接塞入一份 index 越界的原始 JSON，模拟旧版本写下的数据
      await box.put(
        'last',
        '{"queue":[{"id":"x","sourceId":"netease","title":"X","artist":"A"}],'
            '"index":42,"positionMs":1000,"mode":"sequential","shuffleOn":false,'
            '"savedAt":0}',
      );

      final loaded = repository.load();
      expect(loaded, isNotNull, reason: '越界 index 应被钳制而不是丢弃快照');
      expect(loaded!.index, 0);
      expect(loaded.track?.id, 'x');
    });

    test('损坏 JSON 返回 null 而非抛异常', () async {
      repository = ResumeRepository(box: box);
      await box.put('last', '{not json');
      expect(repository.load(), isNull);
    });

    test('未知 mode 回退到顺序播放', () async {
      repository = ResumeRepository(box: box);
      await box.put(
        'last',
        '{"queue":[{"id":"x","sourceId":"netease","title":"X","artist":"A"}],'
            '"index":0,"positionMs":0,"mode":"bogus","shuffleOn":false,'
            '"savedAt":0}',
      );
      expect(repository.load()!.mode, PlayMode.sequential);
    });
  });

  group('持久化窗口裁剪', () {
    test('超长队列按上限裁剪且 index 重定位到当前曲', () async {
      repository = ResumeRepository(box: box);
      final queue = List<Track>.generate(500, (i) => track('$i'));
      const currentIndex = 400;

      await repository.save(snapshot(queue: queue, index: currentIndex));

      final loaded = repository.load()!;
      expect(
        loaded.queue.length,
        lessThanOrEqualTo(ResumeRepository.maxQueuePersist),
      );
      // 裁剪后当前曲必须仍是原来那一首
      expect(loaded.track?.id, '$currentIndex');
      expect(loaded.index, inInclusiveRange(0, loaded.queue.length - 1));
    });

    test('恰好等于上限时不裁剪', () async {
      repository = ResumeRepository(box: box);
      final queue = List<Track>.generate(
        ResumeRepository.maxQueuePersist,
        (i) => track('$i'),
      );
      await repository.save(snapshot(queue: queue, index: 10));

      expect(
        repository.load()!.queue,
        hasLength(ResumeRepository.maxQueuePersist),
      );
    });
  });

  group('往返一致', () {
    test('队列 / index / 位置 / 模式 / 洗牌 全部保真', () async {
      repository = ResumeRepository(box: box);
      final queue = [track('a'), track('b'), track('c')];
      await repository.save(
        ResumePlayback(
          queue: queue,
          index: 2,
          position: const Duration(seconds: 42),
          mode: PlayMode.loopAll,
          shuffleOn: true,
          savedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
      );

      final loaded = repository.load()!;
      expect(loaded.queue.map((t) => t.key), queue.map((t) => t.key));
      expect(loaded.index, 2);
      expect(loaded.position, const Duration(seconds: 42));
      expect(loaded.mode, PlayMode.loopAll);
      expect(loaded.shuffleOn, isTrue);
      expect(loaded.savedAt.millisecondsSinceEpoch, 1700000000000);
    });

    test('clear 删除记录', () async {
      repository = ResumeRepository(box: box);
      await repository.save(snapshot(queue: [track('a')], index: 0));
      await repository.clear();
      expect(repository.load(), isNull);
    });
  });
}
