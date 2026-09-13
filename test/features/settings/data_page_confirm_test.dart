import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/theme/app_tokens.dart';
import 'package:musaic/features/library/data/library_repository.dart';
import 'package:musaic/features/player/audio_handler.dart';
import 'package:musaic/features/player/data/resume_repository.dart';
import 'package:musaic/features/search/data/search_history_repository.dart';
import 'package:musaic/features/settings/settings_page.dart';
import 'package:musaic/features/settings/settings_providers.dart';

/// 破坏性操作**二次确认**的 UI 接线测试（用户层交互计划 2.1）。
///
/// ## 被固化的缺陷
///
/// 数据管理页（[DataPage]）的四个清除项此前**点下去立即执行**，只在事后
/// 弹一条 toast。这些都是不可恢复操作（清空收藏、清空播放/搜索历史），
/// 误触后用户没有任何挽回余地。
///
/// 修复后每个操作都必须先弹确认框；**用户未确认时绝不能发生任何写入**。
/// 因此本文件的核心断言是**否定式**的：点击条目后立刻断言仓库
/// **尚未**被调用——这正是修复前的行为。
///
/// ## 分层：本文件内**不出现任何 `await` 真实 Hive 写盘**
///
/// `testWidgets` 的伪造时钟会让 Hive 的真实写盘永不完成，测试挂起且
/// **没有断言失败**（排查代价极高，见 `test/e2e/main_flow_test.dart`
/// 顶部的分层说明）。因此这里两个仓库都用内存假实现：
/// 本文件只验证「界面是否先确认、再调用正确的方法」。
/// 真实落盘语义由 `library_repository_test.dart` 与
/// `test/e2e/main_flow_test.dart` 覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLibraryRepository repository;
  late _FakeSearchHistoryRepository searchHistory;
  late Directory tempDir;
  late Box<String> resumeBox;
  late Box<String> settingsBox;

  setUpAll(() async {
    // 这两个 Box 只在 build 期间被**同步读取**（无 await），
    // 因此不会触发上面说的挂起问题。
    tempDir = await Directory.systemTemp.createTemp('musaic_data_page');
    Hive.init(tempDir.path);
    resumeBox = await Hive.openBox<String>('dp_resume');
    settingsBox = await Hive.openBox<String>('dp_settings');
  });

  tearDownAll(() async {
    for (final box in [resumeBox, settingsBox]) {
      if (box.isOpen) await box.close();
    }
    await Hive.close();
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  setUp(() {
    repository = _FakeLibraryRepository();
    searchHistory = _FakeSearchHistoryRepository();
  });

  /// 固定曲目：三处用例共用，避免重复字面量（const 可满足 lint）。
  const favoritedSong = Track(
    id: 'f1',
    sourceId: 'netease',
    title: '歌f1',
    artist: 'Beyond',
  );

  Widget host() {
    return ProviderScope(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repository),
        searchHistoryRepositoryProvider.overrideWithValue(searchHistory),
        sourceRegistryProvider.overrideWithValue(SourceRegistry()),
        audioHandlerProvider.overrideWithValue(
          MusaicAudioHandler(player: _StubPlayer()),
        ),
        resumeRepositoryProvider.overrideWithValue(
          ResumeRepository(box: resumeBox),
        ),
        appSettingsRepositoryProvider.overrideWithValue(
          AppSettingsRepository(box: settingsBox),
        ),
      ],
      child: MaterialApp(theme: AppTokens.darkTheme, home: const DataPage()),
    );
  }

  /// 点击某个清除条目，等确认框弹出。
  Future<void> tapEntry(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  /// 找到确认按钮（文案随操作而定），点它。
  Future<void> confirm(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(FilledButton, label));
    await tester.pumpAndSettle();
  }

  group('清空喜欢的音乐（2.1 回归）', () {
    testWidgets('点击后先弹确认框，未确认时不得清空收藏', (tester) async {
      repository.seedFavorite(favoritedSong);

      await tester.pumpWidget(host());
      await tapEntry(tester, '清空喜欢的音乐');

      // 确认框出现，且说明了不可恢复
      expect(find.text('清空喜欢的音乐？'), findsOneWidget);
      expect(find.textContaining('不可恢复'), findsOneWidget);

      // 核心否定断言：还没确认，仓库绝不能被调用（这正是修复前的行为）
      expect(
        repository.clearFavoritesCalls,
        0,
        reason: '未确认前不得执行清空（2.1 破坏性操作二次确认）',
      );
    });

    testWidgets('取消后不得清空收藏', (tester) async {
      repository.seedFavorite(favoritedSong);

      await tester.pumpWidget(host());
      await tapEntry(tester, '清空喜欢的音乐');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(repository.clearFavoritesCalls, 0);
      expect(find.text('清空喜欢的音乐？'), findsNothing);
    });

    testWidgets('确认后才真正清空并给出反馈', (tester) async {
      repository.seedFavorite(favoritedSong);

      await tester.pumpWidget(host());
      await tapEntry(tester, '清空喜欢的音乐');
      await confirm(tester, '清空');

      expect(repository.clearFavoritesCalls, 1);
      expect(find.text('已清空喜欢的音乐'), findsOneWidget);
    });
  });

  group('清除播放历史（2.1 回归）', () {
    testWidgets('未确认时不得清空历史，确认后调用 clearHistory', (tester) async {
      await tester.pumpWidget(host());
      await tapEntry(tester, '清除播放历史');

      expect(find.text('清除播放历史？'), findsOneWidget);
      expect(repository.clearHistoryCalls, 0);

      await confirm(tester, '清空');

      expect(repository.clearHistoryCalls, 1);
      expect(find.text('播放历史已清除'), findsOneWidget);
    });
  });

  group('清除搜索历史（2.1 回归）', () {
    testWidgets('未确认时不得清空搜索历史', (tester) async {
      searchHistory.seed('海阔天空');

      await tester.pumpWidget(host());
      await tapEntry(tester, '清除搜索历史');

      expect(find.text('清除搜索历史？'), findsOneWidget);
      // 核心否定断言：未确认，历史数据必须还在
      expect(
        searchHistory.clearCalls,
        0,
        reason: '未确认前不得清空搜索历史（2.1 破坏性操作二次确认）',
      );
      expect(searchHistory.load(), isNotEmpty);
    });

    testWidgets('确认后才真正清空搜索历史', (tester) async {
      searchHistory.seed('海阔天空');

      await tester.pumpWidget(host());
      await tapEntry(tester, '清除搜索历史');
      await confirm(tester, '清空');

      expect(searchHistory.clearCalls, 1);
      expect(searchHistory.load(), isEmpty);
      expect(find.text('搜索历史已清除'), findsOneWidget);
    });
  });
}

/// 内存假搜索历史仓库：只记录调用，不做任何 IO。
class _FakeSearchHistoryRepository implements SearchHistoryRepository {
  final List<String> _keywords = <String>[];

  int clearCalls = 0;

  void seed(String keyword) => _keywords.add(keyword);

  @override
  List<String> load() => List<String>.unmodifiable(_keywords);

  @override
  Future<List<String>> add(String keyword) async {
    _keywords.insert(0, keyword);
    return load();
  }

  @override
  Future<List<String>> clear() async {
    clearCalls++;
    _keywords.clear();
    return const <String>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('假搜索历史仓库未实现：${invocation.memberName}');
}

/// 内存假仓库：记录破坏性调用次数，不做任何 IO。
///
/// 未实现的方法经 [noSuchMethod] 抛错——界面一旦新增对仓库的调用
/// 会立刻暴露，而不是被静默忽略。
class _FakeLibraryRepository implements LibraryRepository {
  final List<Track> _favoriteTracks = <Track>[];

  int clearFavoritesCalls = 0;
  int clearHistoryCalls = 0;

  void seedFavorite(Track track) => _favoriteTracks.add(track);

  @override
  List<Track> get favorites => List<Track>.of(_favoriteTracks);

  @override
  bool isFavorite(String trackKey) =>
      _favoriteTracks.any((t) => t.key == trackKey);

  @override
  Future<void> clearFavorites() async {
    clearFavoritesCalls++;
    _favoriteTracks.clear();
  }

  @override
  Future<void> clearHistory() async {
    clearHistoryCalls++;
  }

  @override
  List<Track> recentHistory({int limit = 50}) => const <Track>[];

  @override
  Stream<BoxEvent> watchFavorites() => const Stream<BoxEvent>.empty();

  @override
  Stream<BoxEvent> watchHistory() => const Stream<BoxEvent>.empty();

  @override
  Stream<BoxEvent> watchPlaylists() => const Stream<BoxEvent>.empty();

  @override
  List<String> get playlistNames => const <String>[];

  @override
  List<Track> playlistTracks(String name) => const <Track>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('假仓库未实现：${invocation.memberName}');
}

/// 桩播放器：单元测试环境没有 just_audio 原生实现。
class _StubPlayer extends Mock implements ja.AudioPlayer {
  @override
  Stream<ja.PlayerState> get playerStateStream =>
      const Stream<ja.PlayerState>.empty();

  @override
  Stream<ja.PlaybackEvent> get playbackEventStream =>
      const Stream<ja.PlaybackEvent>.empty();

  @override
  ja.PlaybackEvent get playbackEvent =>
      ja.PlaybackEvent(processingState: ja.ProcessingState.idle);

  @override
  bool get playing => false;

  @override
  ja.ProcessingState get processingState => ja.ProcessingState.idle;

  @override
  Duration get position => Duration.zero;

  @override
  Duration get bufferedPosition => Duration.zero;

  @override
  double get speed => 1.0;

  @override
  double get volume => 1.0;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> dispose() async {}
}
