import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/features/home/home_page.dart';
import 'package:musaic/features/library/data/library_repository.dart';
import 'package:musaic/features/player/data/resume_repository.dart';
import 'package:musaic/features/player/player_notifier.dart';

/// 首页丰富化（日常可用性计划 D6）。
///
/// 重点钉住两条容易回退的契约：
/// 1. **无断点快照时不显示「继续收听」卡**——不留空占位。
///    这是「打开应用第一眼看到的是内容而不是空壳」的底线；
/// 2. 快捷入口的数量取自本地资料库，且三入口齐全。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box<String> favoritesBox;
  late Box<String> historyBox;
  late Box<String> playlistsBox;
  late Box<String> resumeBox;
  late LibraryRepository library;
  late ResumeRepository resume;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_home_test');
    Hive.init(tempDir.path);
    favoritesBox = await Hive.openBox<String>('home_favorites');
    historyBox = await Hive.openBox<String>('home_history');
    playlistsBox = await Hive.openBox<String>('home_playlists');
    resumeBox = await Hive.openBox<String>('home_resume');
  });

  tearDownAll(() async {
    await favoritesBox.close();
    await historyBox.close();
    await playlistsBox.close();
    await resumeBox.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  setUp(() async {
    await favoritesBox.clear();
    await historyBox.clear();
    await playlistsBox.clear();
    await resumeBox.clear();
    library = LibraryRepository(
      favoritesBox: favoritesBox,
      historyBox: historyBox,
      playlistsBox: playlistsBox,
    );
    resume = ResumeRepository(box: resumeBox);
  });

  Track song(String id, {String artist = 'Beyond'}) =>
      Track(id: id, sourceId: 'netease', title: '海阔天空$id', artist: artist);

  /// 在 `testWidgets` 的 fake-async 区里执行**真实 Hive IO**。
  ///
  /// 这是本文件最容易踩的坑：`testWidgets` 默认把异步任务放在伪造时钟里，
  /// 而 Hive 的磁盘写入依赖真实事件循环，`await box.put(...)` 会永远挂起
  /// （表现为测试「跑完但不结束」，最后被测试框架超时杀掉）。
  /// 因此所有直接落盘的操作都必须经 [WidgetTester.runAsync] 执行。
  Future<T> realIo<T>(WidgetTester tester, Future<T> Function() action) async {
    final result = await tester.runAsync(action);
    return result as T;
  }

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(library),
          resumeRepositoryProvider.overrideWithValue(resume),
          // 首页不直接查渠道，但快捷入口/空态依赖注册表存在
          sourceRegistryProvider.overrideWithValue(SourceRegistry()),
          // 播放器桩：不触碰 audioHandler，避免测试环境初始化音频栈
          playerNotifierProvider.overrideWith(_StubPlayerNotifier.new),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('无断点快照时不显示「继续收听」卡（不留空占位）', (tester) async {
    await pumpHome(tester);

    expect(find.text('继续收听'), findsNothing, reason: '没有快照就不该出现这张卡，而不是渲染一张空卡');
    expect(find.text('继续播放'), findsNothing);

    // 无历史时应落到「扫描本地音乐」引导，说明首页仍然可用
    expect(find.text('扫描本地音乐'), findsOneWidget);
  });

  testWidgets('有断点快照时显示继续收听卡与「继续播放」按钮', (tester) async {
    await realIo(
      tester,
      () => resume.save(
        ResumePlayback(
          queue: [song('1'), song('2')],
          index: 1,
          position: const Duration(seconds: 30),
          savedAt: DateTime.now(),
        ),
      ),
    );

    await pumpHome(tester);

    expect(find.text('继续收听'), findsOneWidget);
    expect(find.text('继续播放'), findsOneWidget);
    // 快照里的当前曲目（index = 1）
    expect(find.text('海阔天空2'), findsOneWidget);
    expect(find.textContaining('Beyond'), findsWidgets);
  });

  testWidgets('快捷入口齐全且数量取自本地资料库', (tester) async {
    await realIo(
      tester,
      () => favoritesBox.put(
        song('f1').key,
        '{"id":"f1","sourceId":"netease","title":"t","artist":"a"}',
      ),
    );
    await realIo(tester, () => library.createPlaylist('通勤'));

    await pumpHome(tester);

    expect(find.text('喜欢'), findsOneWidget);
    expect(find.text('歌单'), findsOneWidget);
    expect(find.text('最近播放'), findsOneWidget);

    // 喜欢 1 首、歌单 1 个、历史 0 条
    expect(find.text('1'), findsNWidgets(2));
    expect(find.text('0'), findsOneWidget);
  });
}

/// 跳过 audioHandler 初始化的播放器状态（与其他 Widget 测试同款桩）。
class _StubPlayerNotifier extends PlayerNotifier {
  @override
  PlayerState build() => const PlayerState();
}
