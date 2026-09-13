import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/features/library/data/backup_service.dart';
import 'package:musaic/features/library/data/library_repository.dart';

void main() {
  late Directory tempDir;
  late Box<String> favoritesBox;
  late Box<String> historyBox;
  late Box<String> playlistsBox;
  late LibraryRepository repository;

  Track makeTrack(String id) =>
      Track(id: id, sourceId: 'netease', title: 't$id', artist: 'a');

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
      await repository.addManyToPlaylist('晨跑', [
        makeTrack('1'),
        makeTrack('3'),
      ]);

      final tracks = repository.playlistTracks('晨跑');
      expect(tracks.map((t) => t.id), ['1', '2', '3']);
    });

    test('replacePlaylistTracks 整体替换且保留创建时间', () async {
      await repository.createPlaylist('下班');
      await repository.addManyToPlaylist('下班', [makeTrack('a')]);
      final created = (playlistsBox.get('下班')!.contains('"createdAt"'));
      expect(created, isTrue);

      await repository.replacePlaylistTracks('下班', [
        makeTrack('x'),
        makeTrack('y'),
      ]);
      final tracks = repository.playlistTracks('下班');
      expect(tracks.map((t) => t.id), ['x', 'y']);
    });
  });

  group('歌单排序（基准项「播放列表 · 排序」）', () {
    /// 带可控元数据的曲目：排序要覆盖标题/艺术家/时长三个维度，
    /// 其中时长可为 null（元数据缺失时的兜底路径）。
    Track rich(String id, {String? title, String? artist, Duration? dur}) =>
        Track(
          id: id,
          sourceId: 'netease',
          title: title ?? 't$id',
          artist: artist ?? 'a',
          duration: dur,
        );

    test('按标题排序：结果写回存储，顺序即播放顺序', () async {
      await repository.createPlaylist('排序');
      await repository.addManyToPlaylist('排序', [
        rich('1', title: 'Cherry'),
        rich('2', title: 'apple'),
        rich('3', title: 'Banana'),
      ]);

      final ok = await repository.sortPlaylist(
        '排序',
        PlaylistSortOrder.titleAsc,
      );

      expect(ok, isTrue);
      // 大小写不敏感：apple < Banana < Cherry
      expect(repository.playlistTracks('排序').map((t) => t.id), ['2', '3', '1']);
    });

    test('按艺术家排序：同艺术家内按标题', () async {
      await repository.createPlaylist('排序');
      await repository.addManyToPlaylist('排序', [
        rich('1', artist: 'Zoe', title: 'a'),
        rich('2', artist: 'Amy', title: 'z'),
        rich('3', artist: 'Amy', title: 'b'),
      ]);

      await repository.sortPlaylist('排序', PlaylistSortOrder.artistAsc);

      expect(repository.playlistTracks('排序').map((t) => t.id), ['3', '2', '1']);
    });

    test('按时长排序：缺失时长按 0 处理并排在最前（不抛异常）', () async {
      await repository.createPlaylist('排序');
      await repository.addManyToPlaylist('排序', [
        rich('1', dur: const Duration(minutes: 3)),
        rich('2'), // 时长缺失
        rich('3', dur: const Duration(minutes: 1)),
      ]);

      await repository.sortPlaylist('排序', PlaylistSortOrder.durationAsc);

      expect(repository.playlistTracks('排序').map((t) => t.id), ['2', '3', '1']);
    });

    test('同值项按 key 收尾排序：重复排序结果稳定', () async {
      await repository.createPlaylist('排序');
      await repository.addManyToPlaylist('排序', [
        rich('c', title: 'same'),
        rich('a', title: 'same'),
        rich('b', title: 'same'),
      ]);

      await repository.sortPlaylist('排序', PlaylistSortOrder.titleAsc);
      final first = repository.playlistTracks('排序').map((t) => t.id).toList();
      await repository.sortPlaylist('排序', PlaylistSortOrder.titleAsc);
      final second = repository.playlistTracks('排序').map((t) => t.id).toList();

      // 全同值时顺序由 key 决定，且两次一致（否则用户会以为排序没生效）
      expect(first, ['a', 'b', 'c']);
      expect(second, first);
    });

    test('默认顺序不可执行：返回 false 且不改动内容', () async {
      await repository.createPlaylist('排序');
      await repository.addManyToPlaylist('排序', [
        rich('1', title: 'B'),
        rich('2', title: 'A'),
      ]);

      final ok = await repository.sortPlaylist('排序', PlaylistSortOrder.manual);

      expect(ok, isFalse);
      // 排序不可逆（原始顺序不另存），因此不提供「恢复默认」而误改数据
      expect(repository.playlistTracks('排序').map((t) => t.id), ['1', '2']);
    });

    test('歌单不存在或曲目不足 2 首：返回 false 且不报错', () async {
      expect(
        await repository.sortPlaylist('不存在', PlaylistSortOrder.titleAsc),
        isFalse,
      );

      await repository.createPlaylist('单曲');
      await repository.addManyToPlaylist('单曲', [rich('1')]);
      expect(
        await repository.sortPlaylist('单曲', PlaylistSortOrder.titleAsc),
        isFalse,
      );
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
    test('bulkImportHistory 导入后仍裁剪到上限', () async {
      await repository.bulkImportHistory(
        List.generate(LibraryRepository.historyCap + 5, (index) {
          return makeTrack('import-$index');
        }),
      );

      expect(historyBox.length, LibraryRepository.historyCap);
      expect(historyBox.containsKey(makeTrack('import-0').key), isTrue);
    });
  });

  group('历史批量移除（U1 回归）', () {
    test('removeHistory 删除历史且不触碰收藏', () async {
      final a = makeTrack('a');
      final b = makeTrack('b');
      await repository.addHistory(a);
      await repository.addHistory(b);
      // a 同时被收藏：删除历史**不得**取消收藏
      await repository.toggleFavorite(a);

      await repository.removeHistory([a.key]);

      expect(historyBox.containsKey(a.key), isFalse);
      expect(historyBox.containsKey(b.key), isTrue);
      // 关键回归断言：收藏是另一份数据，必须原样保留
      expect(repository.isFavorite(a.key), isTrue);
      expect(favoritesBox.containsKey(a.key), isTrue);
    });

    test('removeHistory 空集合是安全空操作', () async {
      await repository.addHistory(makeTrack('a'));
      await repository.removeHistory(const <String>[]);
      expect(historyBox.length, 1);
    });

    test('removeHistory 忽略不存在的 key', () async {
      await repository.addHistory(makeTrack('a'));
      await repository.removeHistory(['netease:不存在']);
      expect(historyBox.length, 1);
      expect(repository.recentHistory().length, 1);
    });
  });

  group('资料库备份（BackupService）', () {
    test('快照 → JSON → 解析 往返一致', () async {
      final service = BackupService(library: repository);
      await repository.toggleFavorite(makeTrack('fav1'));
      await repository.createPlaylist('晨跑');
      await repository.addManyToPlaylist('晨跑', [
        makeTrack('p1'),
        makeTrack('p2'),
      ]);
      await repository.addHistory(makeTrack('h1'));

      final backup = service.snapshot();
      final restored = service.decode(backup.encodePretty());

      expect(restored.favorites.map((t) => t.id), ['fav1']);
      expect(restored.playlists['晨跑']?.map((t) => t.id), ['p1', 'p2']);
      expect(restored.history.map((t) => t.id), contains('h1'));
      expect(restored.schema, LibraryBackup.currentSchema);
    });

    test('合并式导入：按 key 去重，不覆盖本地已有数据', () async {
      final service = BackupService(library: repository);
      // 本地已有：收藏 a；歌单「本地」含 x
      await repository.toggleFavorite(makeTrack('a'));
      await repository.createPlaylist('本地');
      await repository.addManyToPlaylist('本地', [makeTrack('x')]);

      const raw = '''
      {
        "schema": 1,
        "exportedAt": "2026-08-27T10:00:00.000",
        "favorites": [
          {"id": "a", "sourceId": "netease", "title": "A", "artist": "s"},
          {"id": "b", "sourceId": "kugou", "title": "B", "artist": "s"}
        ],
        "playlists": {
          "备份歌单": [
            {"id": "y", "sourceId": "netease", "title": "Y", "artist": "s"}
          ],
          "本地": [
            {"id": "x", "sourceId": "netease", "title": "X", "artist": "s"},
            {"id": "z", "sourceId": "qqmusic", "title": "Z", "artist": "s"}
          ]
        },
        "history": [
          {"id": "b", "sourceId": "kugou", "title": "B", "artist": "s"}
        ]
      }''';
      final result = await service.importBackup(service.decode(raw));

      // 收藏并集去重
      expect(repository.favorites.map((t) => t.id).toSet(), {'a', 'b'});
      // 本地歌单保留 + 新增 z（按 key 去重）
      expect(repository.playlistTracks('本地').map((t) => t.id), ['x', 'z']);
      // 缺失歌单被创建
      expect(repository.playlistNames, contains('备份歌单'));
      expect(result.favorites, 2);
      expect(result.playlists, 2);
    });

    test('非法 JSON 抛 FormatException 且不入库', () async {
      final service = BackupService(library: repository);
      expect(() => service.decode('{broken'), throwsFormatException);
      expect(() => service.decode('[1,2]'), throwsFormatException);
      expect(repository.favorites, isEmpty);
    });

    test('新版本 schema 拒绝导入', () async {
      final service = BackupService(library: repository);
      const raw = '{"schema": 999, "exportedAt": "2026-08-27T10:00:00.000"}';
      expect(() => service.decode(raw), throwsFormatException);
    });

    test('导入中途失败：回滚到导入前状态（B17）', () async {
      final service = BackupService(library: repository);
      // 本地已有收藏 fav-keep
      await repository.toggleFavorite(makeTrack('fav-keep'));

      // 备份中含非法歌单名（trim 后为空）→ 在歌单步骤抛 ArgumentError
      const raw = '''
      {
        "schema": 1,
        "exportedAt": "2026-08-27T10:00:00.000",
        "favorites": [
          {"id": "fav-keep", "sourceId": "netease", "title": "A", "artist": "s"}
        ],
        "playlists": {
          "   ": [
            {"id": "p", "sourceId": "netease", "title": "P", "artist": "s"}
          ]
        },
        "history": []
      }''';

      await expectLater(
        service.importBackup(service.decode(raw)),
        throwsArgumentError,
      );

      // 回滚生效：收藏恢复原样（新增的收藏被撤销），无残留歌单
      expect(repository.favorites.map((t) => t.id), ['fav-keep']);
      expect(repository.playlistNames, isEmpty);
      expect(repository.recentHistory(), isEmpty);
    });
  });

  group('歌单并发锁（迭代计划 §8.4）', () {
    test('同名歌单并发写串行执行：两次批量加入互不覆盖', () async {
      await repository.createPlaylist('并发');
      // 并发触发两个「读-改-写」：无锁时后者会覆盖前者的写入
      await Future.wait([
        repository.addManyToPlaylist('并发', [makeTrack('lock-a')]),
        repository.addManyToPlaylist('并发', [makeTrack('lock-b')]),
      ]);
      final ids = repository.playlistTracks('并发').map((t) => t.id).toSet();
      expect(ids, {'lock-a', 'lock-b'});
    });

    test('歌单名 trim 规范化，空名拒绝', () async {
      await repository.createPlaylist('  带空格  ');
      expect(repository.playlistNames, contains('带空格'));
      // trim 后同名歌单不会重复创建
      await repository.createPlaylist(' 带空格 ');
      expect(repository.playlistNames.where((n) => n == '带空格'), hasLength(1));
      expect(() => repository.createPlaylist('   '), throwsArgumentError);
    });

    test('超长歌单名拒绝', () async {
      final longName = '长' * (LibraryRepository.playlistNameMaxLength + 1);
      expect(() => repository.createPlaylist(longName), throwsArgumentError);
    });
  });

  group('全库快照回滚（迭代计划 §8.6）', () {
    test('restoreSnapshot 完整还原三个 Box', () async {
      await repository.toggleFavorite(makeTrack('snap-fav'));
      await repository.createPlaylist('快照歌单');
      await repository.addManyToPlaylist('快照歌单', [makeTrack('snap-p1')]);
      await repository.addHistory(makeTrack('snap-h1'));
      final snapshot = repository.captureSnapshot();

      // 破坏现场
      await repository.toggleFavorite(makeTrack('snap-fav'));
      await repository.deletePlaylist('快照歌单');
      await repository.addHistory(makeTrack('snap-h2'));

      await repository.restoreSnapshot(snapshot);
      expect(repository.isFavorite(makeTrack('snap-fav').key), isTrue);
      expect(repository.playlistTracks('快照歌单').map((t) => t.id), ['snap-p1']);
      expect(repository.recentHistory().map((t) => t.id), contains('snap-h1'));
      expect(
        repository.recentHistory().map((t) => t.id),
        isNot(contains('snap-h2')),
      );
    });
  });
}
