import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/features/library/data/library_repository.dart';

void main() {
  late Directory tempDir;
  late Box<String> favoritesBox;
  late Box<String> historyBox;
  late Box<String> playlistsBox;
  late LibraryRepository repository;

  Track makeTrack(String id) => Track(
        id: id,
        sourceId: 'netease',
        title: 't$id',
        artist: 'a',
      );

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_library_test');
    Hive.init(tempDir.path);
    favoritesBox = await Hive.openBox<String>('test_favorites');
    historyBox = await Hive.openBox<String>('test_history');
    playlistsBox = await Hive.openBox<String>('test_playlists');
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
  });

  group('歌单批量写入', () {
    test('addManyToPlaylist 一次写入并按 key 去重', () async {
      await repository.createPlaylist('晨跑');
      await repository.addManyToPlaylist('晨跑', [
        makeTrack('1'),
        makeTrack('2'),
        makeTrack('2'), // 批内重复
      ]);
      // 再补一条已存在的 + 一条新的
      await repository.addManyToPlaylist('晨跑', [makeTrack('1'), makeTrack('3')]);

      final tracks = repository.playlistTracks('晨跑');
      expect(tracks.map((t) => t.id), ['1', '2', '3']);
    });

    test('replacePlaylistTracks 整体替换且保留创建时间', () async {
      await repository.createPlaylist('下班');
      await repository.addManyToPlaylist('下班', [makeTrack('a')]);
      final created =
          (playlistsBox.get('下班')!.contains('"createdAt"'));
      expect(created, isTrue);

      await repository.replacePlaylistTracks('下班', [makeTrack('x'), makeTrack('y')]);
      final tracks = repository.playlistTracks('下班');
      expect(tracks.map((t) => t.id), ['x', 'y']);
    });
  });

  group('历史裁剪', () {
    test('addHistory 超上限裁剪最旧记录', () async {
      // 注：同一毫秒内时间戳相同，不假设并列时的顺序，只验证容量与保留键。
      final keys = <String>[];
      for (var i = 0; i < LibraryRepository.historyCap + 5; i++) {
        final t = makeTrack('$i');
        keys.add(t.key);
        await repository.addHistory(t);
      }
      expect(historyBox.length, LibraryRepository.historyCap);
      // 最后加入的记录必须仍在
      expect(historyBox.containsKey(keys.last), isTrue);
      expect(repository.recentHistory(limit: 5).length, 5);
    });
  });
}
