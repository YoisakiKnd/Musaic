import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/logging/app_logger.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/theme/app_tokens.dart';
import 'package:musaic/features/library/data/library_repository.dart';
import 'package:musaic/features/library/library_page.dart';
import 'package:musaic/features/player/audio_handler.dart';
import 'package:musaic/features/player/data/resume_repository.dart';
import 'package:musaic/features/settings/settings_providers.dart';

/// 资料库页「批量移除」的 **UI 接线测试**（U1 数据正确性回归）。
///
/// ## 被固化的缺陷
///
/// 「喜欢」与「最近播放」两个 tab 共用同一个 `_TrackListWithActions`，
/// 而它的 `_removeSelected()` 曾**无条件调用 `toggleFavorite`** 来「移除」。
/// 对收藏页这恰好等价，对历史页则完全错误：选中的历史条目删不掉，
/// 反而把同名曲目悄悄加进（或移出）了收藏——用户可见的数据被静默改写。
///
/// 因此本文件的核心断言是**否定式**的：
/// 在历史页移除所选后，`removedHistory` 必须收到 key，
/// 且 `favoriteToggles` **必须为空**。
///
/// ## 分层
///
/// 仓库用内存假实现（不碰 Hive）：这里只验证「界面调用了正确的方法」。
/// 真实落盘语义由 `test/features/library/library_repository_test.dart`
/// 的 `removeHistory` 用例与 `test/e2e/main_flow_test.dart` 覆盖。
/// 理由同 `add_to_playlist_sheet_test.dart`：`testWidgets` 的伪造时钟
/// 会让真实 Hive 写盘永不完成，测试挂起且无断言失败，排查代价极高。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLibraryRepository repository;
  late Directory tempDir;
  late Box<String> resumeBox;
  late Box<String> settingsBox;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_library_page');
    Hive.init(tempDir.path);
    resumeBox = await Hive.openBox<String>('lp_resume');
    settingsBox = await Hive.openBox<String>('lp_settings');
  });

  tearDownAll(() async {
    if (resumeBox.isOpen) await resumeBox.close();
    if (settingsBox.isOpen) await settingsBox.close();
    await Hive.close();
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  setUp(() {
    repository = _FakeLibraryRepository();
    // 失败用例断言 AppLog 记录，逐例清空环形缓冲避免相互污染。
    AppLog.resetRing();
  });

  Track song(String id) =>
      Track(id: id, sourceId: 'netease', title: '歌$id', artist: 'Beyond');

  Widget host() {
    return ProviderScope(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repository),
        // TrackTile 会解析渠道显示徽标；注入空注册表避免它沿组合根
        // 去要 accountRepository（未启动时必然抛错）。
        sourceRegistryProvider.overrideWithValue(SourceRegistry()),
        audioHandlerProvider.overrideWithValue(
          MusaicAudioHandler(player: _StubPlayer()),
        ),
        resumeRepositoryProvider.overrideWithValue(
          ResumeRepository(box: resumeBox),
        ),
        // PlayerNotifier.build() 会读设置恢复音量/倍速/模式。
        appSettingsRepositoryProvider.overrideWithValue(
          AppSettingsRepository(box: settingsBox),
        ),
      ],
      child: MaterialApp(theme: AppTokens.darkTheme, home: const LibraryPage()),
    );
  }

  /// 切到指定 tab 并等待稳定。
  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  /// 进入多选模式并选中第一条曲目。
  Future<void> selectFirst(WidgetTester tester) async {
    await tester.tap(find.byTooltip('批量选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
  }

  group('最近播放批量移除（U1 回归）', () {
    testWidgets('移除所选删除的是历史，绝不改写收藏', (tester) async {
      repository
        ..seedHistory([song('h1'), song('h2')])
        // h1 同时被收藏：移除历史不得取消它的收藏
        ..seedFavorite(song('h1'));

      await tester.pumpWidget(host());
      await openTab(tester, '最近播放');

      expect(find.text('歌h1'), findsOneWidget);

      await selectFirst(tester);
      await tester.tap(find.byTooltip('移除所选'));
      await tester.pumpAndSettle();

      // 正断言：历史删除被调用，且带上了正确的 key
      expect(repository.removedHistory, [
        ['netease:h1'],
      ]);
      // 核心否定断言：绝不能触碰收藏（这正是修复前的行为）
      expect(
        repository.favoriteToggles,
        isEmpty,
        reason: '历史页移除所选不得调用 toggleFavorite（U1 数据正确性缺陷）',
      );
      expect(repository.isFavorite('netease:h1'), isTrue);
    });

    testWidgets('移除后给出明确反馈', (tester) async {
      repository.seedHistory([song('h1')]);

      await tester.pumpWidget(host());
      await openTab(tester, '最近播放');
      await selectFirst(tester);
      await tester.tap(find.byTooltip('移除所选'));
      await tester.pumpAndSettle();

      expect(find.textContaining('已从最近播放移除'), findsOneWidget);
    });
  });

  group('喜欢批量移除', () {
    testWidgets('移除所选取消的是收藏，不调用 removeHistory', (tester) async {
      repository.seedFavorite(song('f1'));

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      // 默认落在「喜欢」tab
      expect(find.text('歌f1'), findsOneWidget);

      await selectFirst(tester);
      await tester.tap(find.byTooltip('移除所选'));
      await tester.pumpAndSettle();

      expect(repository.favoriteToggles, ['netease:f1']);
      expect(repository.removedHistory, isEmpty);
    });
  });

  group('批量移除失败反馈（计划 3.3）', () {
    testWidgets('写盘失败给出「移除失败，请重试」并记日志', (tester) async {
      repository
        ..seedHistory([song('h1'), song('h2')])
        ..failRemoveHistory = true;

      await tester.pumpWidget(host());
      await openTab(tester, '最近播放');
      await selectFirst(tester);
      await tester.tap(find.byTooltip('移除所选'));
      await tester.pumpAndSettle();

      expect(
        find.text('移除失败，请重试'),
        findsOneWidget,
        reason: '批量移除失败必须给出可见提示，此前是静默冒泡',
      );
      // 不得谎报成功
      expect(find.textContaining('已从最近播放移除'), findsNothing);
      // 失败必须留日志（AppLog），否则线上无从定位
      final messages = AppLog.records.map((r) => r.message).join('\n');
      expect(messages, contains('批量移除失败'));
      expect(
        AppLog.records.any((r) => r.tag == 'MusaicLibrary'),
        isTrue,
        reason: '失败日志应带 MusaicLibrary 标签',
      );
    });

    testWidgets('失败后列表与选中态保持原样，用户可直接重试', (tester) async {
      repository
        ..seedHistory([song('h1'), song('h2')])
        ..failRemoveHistory = true;

      await tester.pumpWidget(host());
      await openTab(tester, '最近播放');
      await selectFirst(tester);
      await tester.tap(find.byTooltip('移除所选'));
      await tester.pumpAndSettle();

      // 曲目仍在列表里：失败不能假装移除成功
      expect(find.text('歌h1'), findsOneWidget);
      expect(find.text('歌h2'), findsOneWidget);
      // 仍处于多选态，可直接再点一次
      expect(
        find.byTooltip('移除所选'),
        findsOneWidget,
        reason: '失败后应保留多选态，避免用户重新勾选',
      );
    });
  });
}

/// 内存假仓库：只记录调用，不做任何 IO。
///
/// 未实现的方法经 [noSuchMethod] 抛错——界面一旦新增对仓库的调用
/// 会立刻暴露，而不是被静默忽略。
class _FakeLibraryRepository implements LibraryRepository {
  final List<Track> _favoriteTracks = <Track>[];
  final List<Track> _historyTracks = <Track>[];

  final List<String> favoriteToggles = <String>[];
  final List<List<String>> removedHistory = <List<String>>[];

  /// true 时 [removeHistory] 抛错（计划 3.3 失败反馈用例）。
  bool failRemoveHistory = false;

  void seedFavorite(Track track) => _favoriteTracks.add(track);
  void seedHistory(List<Track> tracks) => _historyTracks.addAll(tracks);

  @override
  List<Track> get favorites => List<Track>.of(_favoriteTracks);

  @override
  List<Track> recentHistory({int limit = 50}) =>
      _historyTracks.take(limit).toList();

  @override
  bool isFavorite(String trackKey) =>
      _favoriteTracks.any((t) => t.key == trackKey);

  @override
  Future<bool> toggleFavorite(Track track) async {
    favoriteToggles.add(track.key);
    final index = _favoriteTracks.indexWhere((t) => t.key == track.key);
    if (index >= 0) {
      _favoriteTracks.removeAt(index);
      return false;
    }
    _favoriteTracks.add(track);
    return true;
  }

  @override
  Future<void> removeHistory(Iterable<String> trackKeys) async {
    final keys = trackKeys.toList();
    if (failRemoveHistory) {
      // 模拟写盘失败：必须在**改动内存之前**抛出，
      // 否则「失败后列表保持原样」的断言会被假仓库自己破坏。
      throw StateError('模拟批量移除失败');
    }
    removedHistory.add(keys);
    _historyTracks.removeWhere((t) => keys.contains(t.key));
  }

  // Hive 事件流：测试中不需要推送更新，返回空流即可
  // （Provider 会先 yield 一次当前值，再等待变更）。
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
