import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/features/library/data/backup_service.dart';
import 'package:musaic/features/library/data/library_repository.dart';
import 'package:musaic/features/player/data/resume_repository.dart';
import 'package:musaic/features/player/domain/queue_logic.dart';

/// **数据层主链路端到端测试**（日常可用性计划 T1）。
///
/// 用真实 `LibraryRepository` + 真实 Hive（临时目录，真正落盘）跑通
/// 用户的日常动线：
///
///   搜索到曲目 → 加入歌单 → 收藏 → 重启后仍在 → 备份导出导入
///
/// ## 为什么这层用普通 `test()` 而不是 `testWidgets()`
///
/// `testWidgets` 会把异步任务放进**伪造时钟**，而 Hive 写盘依赖真实事件
/// 循环——`await box.put(...)` 在其中永不完成，测试表现为「跑完但不结束」，
/// 最后被框架超时杀掉。这类失败不是断言失败，排查代价极高
/// （本文件的前身就因此反复挂起，最终改为分层）。
///
/// 因此测试分层：
/// - **本文件**：数据层用普通 `test()`，真实 IO 在真实时钟下跑，稳定且快；
/// - **UI 层**：见 `test/features/library/add_to_playlist_sheet_test.dart`，
///   用假仓库验证「界面是否调用了正确的仓库方法」。
///
/// 两层合起来覆盖「数据正确」与「接线正确」，且各自都在可靠的时钟里。
void main() {
  late Directory tempDir;
  late Box<String> favoritesBox;
  late Box<String> historyBox;
  late Box<String> playlistsBox;
  late Box<String> resumeBox;
  late LibraryRepository repository;

  Track song(String id, String sourceId, {String? title}) => Track(
    id: id,
    sourceId: sourceId,
    title: title ?? '海阔天空',
    artist: 'Beyond',
    album: '乐与怒',
    duration: const Duration(minutes: 5, seconds: 24),
  );

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_e2e_data');
    Hive.init(tempDir.path);
    favoritesBox = await Hive.openBox<String>('e2e_fav');
    historyBox = await Hive.openBox<String>('e2e_hist');
    playlistsBox = await Hive.openBox<String>('e2e_pl');
    resumeBox = await Hive.openBox<String>('e2e_resume');
  });

  tearDownAll(() async {
    for (final box in <Box<String>>[
      favoritesBox,
      historyBox,
      playlistsBox,
      resumeBox,
    ]) {
      if (box.isOpen) await box.close();
    }
    await Hive.close();
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // 清理失败不影响测试结论
      }
    }
  });

  setUp(() async {
    await favoritesBox.clear();
    await historyBox.clear();
    await playlistsBox.clear();
    await resumeBox.clear();
    repository = LibraryRepository(
      favoritesBox: favoritesBox,
      historyBox: historyBox,
      playlistsBox: playlistsBox,
    );
  });

  group('主链路：搜索到曲目 → 加入歌单 → 收藏', () {
    test('新建歌单并加入曲目，数据真实落盘', () async {
      final track = song('347230', 'netease');

      await repository.createPlaylist('通勤');
      await repository.addManyToPlaylist('通勤', [track]);

      expect(repository.playlistNames, contains('通勤'));
      expect(repository.playlistTracks('通勤').map((t) => t.key), [
        'netease:347230',
      ]);
      // 直接读 Box 确认真的落盘，而不只是内存视图
      expect(playlistsBox.get('通勤'), isNotNull);
    });

    test('收藏与取消收藏真实落盘', () async {
      final track = song('1', 'netease');

      expect(await repository.toggleFavorite(track), isTrue);
      expect(repository.isFavorite(track.key), isTrue);
      expect(favoritesBox.containsKey(track.key), isTrue);

      expect(await repository.toggleFavorite(track), isFalse);
      expect(repository.isFavorite(track.key), isFalse);
      expect(favoritesBox.containsKey(track.key), isFalse);
    });

    test('播放会写入历史并可按时间倒序取回', () async {
      await repository.addHistory(song('1', 'netease', title: '第一首'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repository.addHistory(song('2', 'netease', title: '第二首'));

      final recent = repository.recentHistory();
      expect(recent.first.title, '第二首', reason: '最近播放应最新在前');
      expect(recent, hasLength(2));
    });

    test('同一首歌的多渠道版本可在同一歌单共存（核心特性）', () async {
      await repository.createPlaylist('对比音质');
      await repository.addManyToPlaylist('对比音质', [
        song('347230', 'netease'),
        song('0039MnYb0qxYhV', 'qqmusic'),
        song('a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6', 'kugou'),
        song('/music/beyond.flac', 'local'),
      ]);

      final tracks = repository.playlistTracks('对比音质');
      expect(tracks, hasLength(4), reason: '用户要自己挑音源（音质/版权/会员各渠道不同），多渠道版本必须共存');
      expect(tracks.map((t) => t.sourceId).toSet(), {
        'netease',
        'qqmusic',
        'kugou',
        'local',
      });
    });

    test('渠道内重复添加仍然去重', () async {
      await repository.createPlaylist('去重');
      await repository.addManyToPlaylist('去重', [
        song('1', 'netease'),
        song('1', 'netease'),
        song('2', 'qqmusic'),
        song('2', 'qqmusic'),
      ]);

      expect(repository.playlistTracks('去重'), hasLength(2));
    });
  });

  group('主链路：重启后数据仍在（持久化验证）', () {
    test('关闭并重开 Box 后，收藏/歌单/历史完整保留', () async {
      await repository.toggleFavorite(song('fav1', 'netease'));
      await repository.createPlaylist('持久化歌单');
      await repository.addManyToPlaylist('持久化歌单', [song('p1', 'qqmusic')]);
      await repository.addHistory(song('h1', 'kugou'));

      // 模拟应用重启：关闭全部 Box 再重新打开
      await favoritesBox.close();
      await historyBox.close();
      await playlistsBox.close();
      favoritesBox = await Hive.openBox<String>('e2e_fav');
      historyBox = await Hive.openBox<String>('e2e_hist');
      playlistsBox = await Hive.openBox<String>('e2e_pl');

      final reopened = LibraryRepository(
        favoritesBox: favoritesBox,
        historyBox: historyBox,
        playlistsBox: playlistsBox,
      );

      expect(reopened.isFavorite('netease:fav1'), isTrue);
      expect(reopened.playlistNames, contains('持久化歌单'));
      expect(reopened.playlistTracks('持久化歌单').map((t) => t.key), [
        'qqmusic:p1',
      ]);
      expect(reopened.recentHistory().map((t) => t.key), contains('kugou:h1'));
    });
  });

  group('主链路：备份导出 → 导入（换机场景）', () {
    test('导出快照后清库再导入，数据完整恢复', () async {
      await repository.toggleFavorite(song('f1', 'netease'));
      await repository.createPlaylist('备份歌单');
      await repository.addManyToPlaylist('备份歌单', [
        song('b1', 'netease'),
        song('b2', 'qqmusic'),
      ]);
      await repository.addHistory(song('h1', 'kugou'));

      final service = BackupService(library: repository);
      final backup = service.snapshot();
      final encoded = backup.encodePretty();

      // 模拟换机：清空全部本地数据
      await favoritesBox.clear();
      await playlistsBox.clear();
      await historyBox.clear();
      expect(repository.favorites, isEmpty);

      // 从导出的 JSON 恢复
      final decoded = service.decode(encoded);
      final result = await service.importBackup(decoded);

      expect(result.favorites, greaterThanOrEqualTo(1));
      expect(repository.isFavorite('netease:f1'), isTrue);
      expect(
        repository.playlistTracks('备份歌单'),
        hasLength(2),
        reason: '备份往返不得丢失多渠道版本',
      );
      expect(
        repository.recentHistory().map((t) => t.key),
        contains('kugou:h1'),
      );
    });

    test('损坏的备份被拒绝，且不破坏现有数据', () async {
      await repository.toggleFavorite(song('safe', 'netease'));
      final service = BackupService(library: repository);

      expect(
        () => service.decode('{ 这不是合法 JSON'),
        throwsA(isA<FormatException>()),
      );
      expect(
        repository.isFavorite('netease:safe'),
        isTrue,
        reason: '坏备份不得影响本地数据',
      );
    });
  });

  group('主链路：断点续播（重启后继续听）', () {
    test('保存快照 → 重开 → 恢复到同一曲目与进度', () async {
      final resume = ResumeRepository(box: resumeBox);
      final queue = [
        song('1', 'netease', title: 'A'),
        song('2', 'netease', title: 'B'),
        song('3', 'netease', title: 'C'),
      ];

      await resume.save(
        ResumePlayback(
          queue: queue,
          index: 2,
          position: const Duration(seconds: 95),
          mode: PlayMode.loopAll,
          shuffleOn: true,
          savedAt: DateTime.now(),
        ),
      );

      // 模拟重启
      await resumeBox.close();
      resumeBox = await Hive.openBox<String>('e2e_resume');
      final reopened = ResumeRepository(box: resumeBox);

      final loaded = reopened.load();
      expect(loaded, isNotNull);
      expect(loaded!.track?.title, 'C', reason: '应恢复到中断时那一首');
      expect(loaded.position, const Duration(seconds: 95));
      expect(loaded.mode, PlayMode.loopAll);
      expect(loaded.shuffleOn, isTrue);
    });
  });

  group('主链路：歌单重命名（D4）', () {
    test('改名后内容与多渠道版本完整保留', () async {
      await repository.createPlaylist('旧名');
      await repository.addManyToPlaylist('旧名', [
        song('1', 'netease'),
        song('2', 'qqmusic'),
      ]);

      expect(await repository.renamePlaylist('旧名', '新名'), isTrue);

      expect(repository.playlistNames, contains('新名'));
      expect(repository.playlistNames, isNot(contains('旧名')));
      expect(repository.playlistTracks('新名'), hasLength(2));
    });
  });

  group('主链路：m3u 导出导入（跨播放器）', () {
    test('导出 m3u 再导入，曲目可还原', () async {
      final service = BackupService(library: repository);
      await repository.createPlaylist('导出源');
      await repository.addManyToPlaylist('导出源', [
        song('1', 'netease'),
        song('2', 'qqmusic'),
      ]);

      final m3u = service.exportM3u('导出源');
      expect(m3u, contains('#EXTM3U'));

      final count = await service.importM3u(m3u, playlistName: '导入目标');
      expect(count, 2);
      expect(repository.playlistTracks('导入目标'), hasLength(2));
    });
  });
}
