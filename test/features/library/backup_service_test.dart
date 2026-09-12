import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/features/library/data/backup_service.dart';
import 'package:musaic/features/library/data/library_repository.dart';

/// 备份导入/回滚的数据安全回归（P1）。
///
/// 覆盖两个曾存在的缺陷：
/// 1. `restoreSnapshot` 用「先 clear 再 putAll」→ 中途失败即空库；
/// 2. 导入过程不持锁 → 用户并发写入被回滚静默抹掉。
void main() {
  late Directory tempDir;
  late Box<String> favoritesBox;
  late Box<String> historyBox;
  late Box<String> playlistsBox;
  late LibraryRepository repository;
  late BackupService service;

  Track makeTrack(String id) =>
      Track(id: id, sourceId: 'netease', title: 't$id', artist: 'a');

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_backup_test');
    Hive.init(tempDir.path);
    favoritesBox = await Hive.openBox<String>('bk_favorites');
    historyBox = await Hive.openBox<String>('bk_history');
    playlistsBox = await Hive.openBox<String>('bk_playlists');
  });

  tearDownAll(() async {
    await favoritesBox.close();
    await historyBox.close();
    await playlistsBox.close();
    await tempDir.delete(recursive: true);
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
    service = BackupService(library: repository);
  });

  group('restoreSnapshot 原子性（P1）', () {
    test('回滚后库内容与快照完全一致（含删除快照外的多余键）', () async {
      await repository.toggleFavorite(makeTrack('keep'));
      await repository.createPlaylist('保留');
      await repository.addManyToPlaylist('保留', [makeTrack('a')]);

      final snapshot = repository.captureSnapshot();

      // 模拟「导入过程中写入了新数据，然后失败」
      await repository.toggleFavorite(makeTrack('intruder'));
      await repository.createPlaylist('多余');
      await repository.addManyToPlaylist('多余', [makeTrack('b')]);

      await repository.restoreSnapshot(snapshot);

      expect(repository.isFavorite('netease:keep'), isTrue);
      expect(
        repository.isFavorite('netease:intruder'),
        isFalse,
        reason: '快照外的键必须被清除',
      );
      expect(repository.playlistNames, contains('保留'));
      expect(
        repository.playlistNames,
        isNot(contains('多余')),
        reason: '快照外的歌单必须被清除',
      );
      expect(repository.playlistTracks('保留').map((t) => t.id), ['a']);
    });

    test('写入阶段不出现「空库窗口」：putAll 先于删除', () async {
      await repository.toggleFavorite(makeTrack('old'));
      final snapshot = repository.captureSnapshot();

      // 快照包含新数据，且旧数据不在其中
      await favoritesBox.put(
        'netease:new',
        makeTrack('new').toJson().toString(),
      );
      final richSnapshot = repository.captureSnapshot();

      // 回滚到 richSnapshot 后，快照内容完整
      await repository.restoreSnapshot(richSnapshot);
      expect(repository.isFavorite('netease:new'), isTrue);

      // 回滚到空快照 → 全清
      await repository.restoreSnapshot(snapshot);
      expect(favoritesBox.length, 1);
      expect(repository.isFavorite('netease:old'), isTrue);
    });
  });

  group('导入互斥（P1）', () {
    test('导入失败时回滚，且回滚不吞掉原始异常', () async {
      await repository.toggleFavorite(makeTrack('existing'));
      final backup = LibraryBackup(
        favorites: [makeTrack('incoming')],
        // 空名歌单会触发 createPlaylist 的校验失败 → 走回滚分支
        playlists: <String, List<Track>>{
          '   ': [makeTrack('x')],
        },
        history: const <Track>[],
        exportedAt: DateTime.now(),
      );

      await expectLater(
        service.importBackup(backup),
        throwsA(isA<ArgumentError>()),
      );
      // 回滚成功：原有收藏保持，导入的新收藏被撤销
      expect(repository.isFavorite('netease:existing'), isTrue);
      expect(repository.isFavorite('netease:incoming'), isFalse);
    });

    test('成功导入后收藏/歌单/历史齐备', () async {
      final backup = LibraryBackup(
        favorites: [makeTrack('f1'), makeTrack('f2')],
        playlists: <String, List<Track>>{
          '导入歌单': [makeTrack('p1')],
        },
        history: [makeTrack('h1')],
        exportedAt: DateTime.now(),
      );

      final result = await service.importBackup(backup);
      expect(result.favorites, 2);
      expect(result.playlists, 1);
      expect(repository.isFavorite('netease:f1'), isTrue);
      expect(repository.playlistTracks('导入歌单').map((t) => t.id), ['p1']);
      expect(repository.recentHistory().map((t) => t.id), contains('h1'));
    });
  });
}
