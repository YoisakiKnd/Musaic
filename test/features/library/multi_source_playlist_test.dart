import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/features/library/data/library_repository.dart';

/// **多渠道共存的契约**（产品决策固化）。
///
/// Musaic 的核心特性是「多渠道聚合」，用户明确要求：
/// **同一个本地歌单里可以同时存放来自不同渠道的同一首歌**——
/// 这不是缺陷，是特性。用户需要自己选择用哪个渠道的音源
/// （不同渠道的音质、是否有版权、是否需要会员都不同）。
///
/// 因此：**歌单的去重键必须是渠道相关的 `track.key`**
/// （= `sourceId:id`），而不是跨渠道归一的 `WorkId`。
///
/// 若哪天有人「顺手」把歌单去重改成按作品归一，用户手里
/// 精心挑选的多渠道版本会被静默合并掉——本测试就是拦住这件事的闸门。
///
/// 与之相对，收藏与历史的语义是「我喜欢/我听过**这首歌**」，
/// 跨渠道归一才符合直觉（见 `docs/architecture-evolution.md` §2.4）。
void main() {
  late Directory tempDir;
  late Box<String> favoritesBox;
  late Box<String> historyBox;
  late Box<String> playlistsBox;
  late LibraryRepository repository;

  /// 同一首歌在不同渠道的记录：标题/歌手相同，仅渠道与 id 不同。
  Track sameSongOn(String sourceId, String id) => Track(
    id: id,
    sourceId: sourceId,
    title: '海阔天空',
    artist: 'Beyond',
    album: '乐与怒',
    duration: const Duration(minutes: 5, seconds: 24),
  );

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_multisource_test');
    Hive.init(tempDir.path);
    favoritesBox = await Hive.openBox<String>('ms_favorites');
    historyBox = await Hive.openBox<String>('ms_history');
    playlistsBox = await Hive.openBox<String>('ms_playlists');
  });

  tearDownAll(() async {
    await favoritesBox.close();
    await historyBox.close();
    await playlistsBox.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  setUp(() async {
    await favoritesBox.clear();
    await historyBox.clear();
    await playlistsBox.clear();
    repository = LibraryRepository(
      favoritesBox: favoritesBox,
      historyBox: historyBox,
      playlistsBox: playlistsBox,
    );
  });

  group('同一首歌的多渠道版本可在同一歌单共存', () {
    test('四个渠道的同曲各自保留，不被去重合并', () async {
      await repository.createPlaylist('我的最爱');
      await repository.addManyToPlaylist('我的最爱', [
        sameSongOn('netease', '347230'),
        sameSongOn('qqmusic', '0039MnYb0qxYhV'),
        sameSongOn('kugou', 'abc123hash'),
        sameSongOn('local', '/music/beyond.flac'),
      ]);

      final tracks = repository.playlistTracks('我的最爱');

      expect(tracks, hasLength(4), reason: '同一首歌的四个渠道版本必须全部保留（产品特性，非缺陷）');
      expect(tracks.map((t) => t.sourceId).toSet(), {
        'netease',
        'qqmusic',
        'kugou',
        'local',
      });
      // 曲目元数据一致，仅渠道身份不同
      expect(tracks.map((t) => t.title).toSet(), {'海阔天空'});
      expect(tracks.map((t) => t.key).toSet(), hasLength(4));
    });

    test('同一渠道的同一首重复添加仍然去重（渠道内幂等）', () async {
      await repository.createPlaylist('去重验证');
      await repository.addManyToPlaylist('去重验证', [
        sameSongOn('netease', '347230'),
        sameSongOn('netease', '347230'), // 同渠道同 id：应去重
        sameSongOn('qqmusic', '0039MnYb0qxYhV'),
        sameSongOn('qqmusic', '0039MnYb0qxYhV'), // 同上
      ]);

      final tracks = repository.playlistTracks('去重验证');
      expect(tracks, hasLength(2), reason: '渠道内去重仍须生效，否则重复点「加入歌单」会刷屏');
      expect(tracks.map((t) => t.sourceId).toSet(), {'netease', 'qqmusic'});
    });

    test('分批添加不同渠道版本同样共存', () async {
      await repository.createPlaylist('分批');
      await repository.addToPlaylist('分批', sameSongOn('netease', '1'));
      await repository.addToPlaylist('分批', sameSongOn('qqmusic', '2'));
      await repository.addToPlaylist('分批', sameSongOn('kugou', '3'));

      expect(repository.playlistTracks('分批'), hasLength(3));
    });

    test('移除其中一个渠道版本，不影响其余版本', () async {
      await repository.createPlaylist('移除测试');
      await repository.addManyToPlaylist('移除测试', [
        sameSongOn('netease', '1'),
        sameSongOn('qqmusic', '2'),
        sameSongOn('kugou', '3'),
      ]);

      // 移除中间那条（QQ 版本）
      await repository.removeFromPlaylist('移除测试', 1);

      final remaining = repository.playlistTracks('移除测试');
      expect(remaining, hasLength(2));
      expect(remaining.map((t) => t.sourceId), [
        'netease',
        'kugou',
      ], reason: '移除一个渠道版本不得波及其它渠道');
    });

    test('跨渠道版本在 JSON 往返（备份/导入）后依然共存', () async {
      await repository.createPlaylist('备份往返');
      await repository.addManyToPlaylist('备份往返', [
        sameSongOn('netease', '1'),
        sameSongOn('qqmusic', '2'),
      ]);

      final snapshot = repository.captureSnapshot();
      await repository.restoreSnapshot(snapshot);

      expect(
        repository.playlistTracks('备份往返'),
        hasLength(2),
        reason: '备份回滚不得因归一化而丢渠道版本',
      );
    });

    test('歌单播放全部时四个版本都进入队列（用户可自行切歌）', () async {
      await repository.createPlaylist('播放');
      await repository.addManyToPlaylist('播放', [
        sameSongOn('netease', '1'),
        sameSongOn('qqmusic', '2'),
        sameSongOn('kugou', '3'),
      ]);

      final queue = repository.playlistTracks('播放');
      expect(queue, hasLength(3));
      // 队列中每条的 key 唯一，播放器才能正确索引
      expect(queue.map((t) => t.key).toSet(), hasLength(3));
    });
  });

  group('与收藏/历史的语义差异（对照说明）', () {
    test('歌单按渠道去重；收藏按渠道去重 —— 当前实现一致', () async {
      // 记录当前行为：收藏同样是「渠道相关」的。
      // 设计文档 §2.4 计划把**收藏与历史**改为按作品归一
      // （语义是「我喜欢这首歌」），但**歌单明确不在改造范围**。
      await repository.toggleFavorite(sameSongOn('netease', '1'));
      await repository.toggleFavorite(sameSongOn('qqmusic', '2'));

      expect(
        repository.favorites,
        hasLength(2),
        reason: '收藏当前按渠道存储；改为 workId 归一是 S4 的独立决策',
      );
      expect(repository.favorites.map((t) => t.sourceId).toSet(), {
        'netease',
        'qqmusic',
      });
    });
  });

  group('歌单重命名（日常可用性计划 D4）', () {
    test('改名后内容完整保留，旧名消失', () async {
      await repository.createPlaylist('旧名');
      await repository.addManyToPlaylist('旧名', [
        sameSongOn('netease', '1'),
        sameSongOn('qqmusic', '2'),
      ]);

      final ok = await repository.renamePlaylist('旧名', '新名');

      expect(ok, isTrue);
      expect(repository.playlistNames, contains('新名'));
      expect(repository.playlistNames, isNot(contains('旧名')));
      expect(repository.playlistTracks('新名'), hasLength(2), reason: '重命名不得丢内容');
      expect(repository.playlistTracks('新名').map((t) => t.sourceId), [
        'netease',
        'qqmusic',
      ]);
    });

    test('改名撞名时拒绝，且不覆盖已有歌单', () async {
      await repository.createPlaylist('A');
      await repository.addManyToPlaylist('A', [sameSongOn('netease', '1')]);
      await repository.createPlaylist('B');
      await repository.addManyToPlaylist('B', [sameSongOn('qqmusic', '2')]);

      final ok = await repository.renamePlaylist('A', 'B');

      expect(ok, isFalse, reason: '撞名必须拒绝而非静默覆盖');
      expect(repository.playlistTracks('A'), hasLength(1));
      expect(repository.playlistTracks('B'), hasLength(1));
      expect(repository.playlistTracks('B').first.sourceId, 'qqmusic');
    });

    test('旧名不存在时返回 false', () async {
      expect(await repository.renamePlaylist('不存在', '新名'), isFalse);
    });

    test('同名重命名是 no-op 且返回 true', () async {
      await repository.createPlaylist('同名');
      expect(await repository.renamePlaylist('同名', '同名'), isTrue);
      expect(repository.playlistNames, contains('同名'));
    });

    test('空名 / 超长名被拒绝（沿用既有校验，同步抛错）', () async {
      await repository.createPlaylist('有效');
      // 名字校验在进入异步流程**之前**同步完成，
      // 因此这里用 expect(() => ...) 而非 expectLater（后者接不到同步抛错）。
      expect(() => repository.renamePlaylist('有效', '   '), throwsArgumentError);
      expect(
        () => repository.renamePlaylist('有效', 'x' * 100),
        throwsArgumentError,
      );
      // 失败后原歌单仍在
      expect(repository.playlistNames, contains('有效'));
    });

    test('重命名保留 createdAt（不重置创建时间）', () async {
      await repository.createPlaylist('原始');
      final before = repository.playlistSnapshot()['原始'];
      final ok = await repository.renamePlaylist('原始', '改名后');
      expect(ok, isTrue);
      final after = repository.playlistSnapshot()['改名后'];
      expect(after, isNotNull);
      // 快照是原始 JSON，重命名应原样搬运
      expect(after, before);
    });
  });
}
