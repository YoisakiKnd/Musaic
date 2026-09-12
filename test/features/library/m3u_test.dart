import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/features/library/data/backup_service.dart';
import 'package:musaic/features/library/data/library_repository.dart';

/// m3u 导入导出回归（改进计划 N2）。
///
/// 核心不变量是**往返一致**：`decodeM3u(encodeM3u(x))` 的每个 `Track.key`
/// 必须与原文相同，否则导入后收藏/历史/去重都会认成另一首歌。
void main() {
  Track netease(
    String id, {
    String? title,
    String? artist,
    Duration? duration,
  }) => Track(
    id: id,
    sourceId: 'netease',
    title: title ?? 't$id',
    artist: artist ?? 'a$id',
    duration: duration,
  );

  group('encodeM3u', () {
    test('标准格式：头 + EXTINF + 定位符，非本地渠道写伪 URI', () {
      final text = encodeM3u([
        netease('1', duration: const Duration(seconds: 65)),
      ]);

      expect(
        text,
        '#EXTM3U\n'
        '#EXTINF:65,a1 - t1\n'
        'musaic://netease/1\n',
      );
    });

    test('playlistName 非空才写 #PLAYLIST（空串/空白视为无）', () {
      expect(
        encodeM3u(const <Track>[], playlistName: '我的歌单'),
        startsWith('#EXTM3U\n#PLAYLIST:我的歌单\n'),
      );
      expect(encodeM3u(const <Track>[]), isNot(contains('#PLAYLIST')));
      expect(
        encodeM3u(const <Track>[], playlistName: '   '),
        isNot(contains('#PLAYLIST')),
        reason: '纯空白歌单名不应写出空 #PLAYLIST 行',
      );
    });

    test('本地渠道优先写真实路径（便于外部播放器打开）', () {
      const local = Track(
        id: '/music/a.mp3',
        sourceId: 'local',
        title: '本地曲',
        artist: '歌手',
        sourceData: <String, dynamic>{'path': '/music/a.mp3'},
      );

      expect(encodeM3u([local]), contains('/music/a.mp3\n'));
      expect(encodeM3u([local]), isNot(contains('musaic://local')));
    });

    test('时长缺失写 -1；标题/歌手里的换行被压成单行', () {
      const track = Track(
        id: '9',
        sourceId: 'qqmusic',
        title: '第一行\n第二行',
        artist: '歌手',
      );
      final text = encodeM3u([track]);

      expect(text, contains('#EXTINF:-1,歌手 - 第一行 第二行\n'));
      // 换行若原样写入会伪造出一条条目行，破坏行格式。
      expect(text.split('\n').where((l) => l.isNotEmpty).length, 3);
    });
  });

  group('decodeM3u', () {
    test('空输入 / 只有头 → 空列表', () {
      expect(decodeM3u(''), isEmpty);
      expect(decodeM3u('#EXTM3U\n'), isEmpty);
      expect(decodeM3u('\n\n   \n'), isEmpty);
    });

    test('未知 # 行与坏行跳过而非抛错', () {
      const text =
          '#EXTM3U\n'
          '#PLAYLIST:混合\n'
          '#EXTGRP:分组\n'
          '# 随便一句注释\n'
          '#EXTINF:10,歌手 - 标题\n'
          'musaic://netease/1\n'
          'musaic://只有渠道\n' // 缺 id：坏伪 URI
          'musaic://a/\n' // 缺 id：坏伪 URI
          'musaic://a/%ZZ\n' // 非法百分号编码
          '#EXTINF:20,另一个 - 标题\n'
          'musaic://qqmusic/2\n';

      final tracks = decodeM3u(text);
      expect(tracks.map((t) => t.key), ['netease:1', 'qqmusic:2']);
    });

    test('时长缺失（-1）解析为 null duration', () {
      final tracks = decodeM3u(
        '#EXTM3U\n#EXTINF:-1,歌手 - 无时长\nmusaic://netease/1\n',
      );
      expect(tracks.single.duration, isNull);
      expect(tracks.single.title, '无时长');
      expect(tracks.single.artist, '歌手');
    });

    test('标题/歌手含逗号：只按首个逗号切分 EXTINF', () {
      final tracks = decodeM3u(
        '#EXTM3U\n#EXTINF:125,A, B - C, D\nmusaic://netease/7\n',
      );
      expect(tracks.single.artist, 'A, B');
      expect(tracks.single.title, 'C, D');
      expect(tracks.single.duration, const Duration(seconds: 125));
    });

    test('无 EXTINF 的裸路径条目：按本地曲目解析并带回 path', () {
      final tracks = decodeM3u('#EXTM3U\n/music/b.mp3\n');
      final track = tracks.single;

      expect(track.sourceId, 'local');
      expect(track.id, '/music/b.mp3');
      expect(track.title, 'b.mp3'); // 退回文件名
      expect(track.artist, '');
      expect(track.duration, isNull);
      expect(track.sourceData?['path'], '/music/b.mp3');
    });

    test('EXTINF 无逗号 / 非数字时长：不抛错，退回缺省', () {
      final tracks = decodeM3u(
        '#EXTM3U\n#EXTINF:abc,歌手 - 标题\nmusaic://netease/3\n',
      );
      expect(tracks.single.duration, isNull);
      expect(tracks.single.title, '标题');
    });
  });

  group('往返一致（round-trip）', () {
    test('本地 + 多渠道混合列表：key 与顺序完全一致', () {
      final tracks = <Track>[
        netease(
          '1',
          title: '带,逗号',
          artist: 'A, B',
          duration: const Duration(seconds: 61),
        ),
        const Track(
          id: '/music/本地 曲.mp3',
          sourceId: 'local',
          title: '本地曲',
          artist: '本地歌手',
          duration: Duration(seconds: 3),
          sourceData: <String, dynamic>{'path': '/music/本地 曲.mp3'},
        ),
        const Track(
          id: 'mid/with slash',
          sourceId: 'qqmusic',
          title: '斜杠',
          artist: '',
        ),
        netease('无时长'),
      ];

      final decoded = decodeM3u(encodeM3u(tracks, playlistName: '往返'));

      expect(decoded.map((t) => t.key), tracks.map((t) => t.key).toList());
      // 本地曲目还要能带回路径，否则导入后无法解析音频流。
      expect(decoded[1].sourceData?['path'], '/music/本地 曲.mp3');
      expect(decoded[2].id, 'mid/with slash');
      expect(decoded[3].duration, isNull);
    });

    test('空列表往返仍为空', () {
      expect(decodeM3u(encodeM3u(const <Track>[])), isEmpty);
    });
  });

  group('BackupService.exportM3u / importM3u', () {
    late Directory tempDir;
    late Box<String> favoritesBox;
    late Box<String> historyBox;
    late Box<String> playlistsBox;
    late LibraryRepository repository;
    late BackupService service;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('musaic_m3u_test');
      Hive.init(tempDir.path);
      favoritesBox = await Hive.openBox<String>('m3u_favorites');
      historyBox = await Hive.openBox<String>('m3u_history');
      playlistsBox = await Hive.openBox<String>('m3u_playlists');
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

    test('导出 → 导入到新歌单：曲目与顺序保持', () async {
      await repository.createPlaylist('源歌单');
      await repository.addManyToPlaylist('源歌单', [netease('1'), netease('2')]);

      final text = service.exportM3u('源歌单');
      expect(text, contains('#PLAYLIST:源歌单'));

      final count = await service.importM3u(text, playlistName: '目标歌单');
      expect(count, 2);
      expect(repository.playlistTracks('目标歌单').map((t) => t.key), [
        'netease:1',
        'netease:2',
      ]);
    });

    test('导入到已存在歌单是合并且去重，不覆盖本地曲目', () async {
      await repository.createPlaylist('合并');
      await repository.addManyToPlaylist('合并', [netease('local-only')]);

      final count = await service.importM3u(
        encodeM3u([netease('local-only'), netease('incoming')]),
        playlistName: '合并',
      );

      expect(count, 2, reason: '返回解析条数');
      expect(repository.playlistTracks('合并').map((t) => t.key), [
        'netease:local-only',
        'netease:incoming',
      ], reason: '已存在曲目不重复写入');
    });

    test('空文本导入返回 0 且不创建歌单', () async {
      expect(await service.importM3u('', playlistName: '不该存在'), 0);
      expect(repository.playlistNames, isNot(contains('不该存在')));
    });

    test('导出不存在的歌单不抛错，只有头', () {
      expect(service.exportM3u('不存在'), '#EXTM3U\n#PLAYLIST:不存在\n');
    });
  });

  group('LibraryRepository.clearFavorites（P2）', () {
    late Directory tempDir;
    late Box<String> favoritesBox;
    late Box<String> historyBox;
    late Box<String> playlistsBox;
    late LibraryRepository repository;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('musaic_clear_fav_test');
      Hive.init(tempDir.path);
      favoritesBox = await Hive.openBox<String>('clear_favorites');
      historyBox = await Hive.openBox<String>('clear_history');
      playlistsBox = await Hive.openBox<String>('clear_playlists');
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

    test('一次清空全部收藏，且不动历史与歌单', () async {
      await repository.addAllFavorites([netease('1'), netease('2')]);
      await repository.addHistory(netease('1'));
      await repository.createPlaylist('保留');

      await repository.clearFavorites();

      expect(repository.favorites, isEmpty);
      expect(favoritesBox.length, 0);
      expect(repository.recentHistory(), isNotEmpty, reason: '不应波及历史');
      expect(repository.playlistNames, contains('保留'));
    });

    test('空收藏上调用是安全的幂等操作', () async {
      await repository.clearFavorites();
      expect(repository.favorites, isEmpty);
    });
  });
}
