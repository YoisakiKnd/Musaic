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
import 'package:musaic/features/player/audio_handler.dart';
import 'package:musaic/features/player/player_notifier.dart';
import 'package:musaic/features/player/player_page.dart';
import 'package:musaic/features/settings/settings_providers.dart';

/// 播放页收藏开关的**失败反馈**回归测试（用户层交互计划 3.3 (b)）。
///
/// ## 被固化的缺陷
///
/// `_PlayerPageState._toggleFavorite` 此前**没有 try/catch**：只有成功路径
/// 会弹「已加入喜欢」，写盘失败时异常直接冒泡出 async 回调，用户点下去
/// **没有任何反应**——不报错、不提示，也看不出收藏到底成没成。
/// 播放页是收藏的主要入口（迷你条 / 播放页），静默失败等于功能不可信。
///
/// 修复后失败必须给出可见提示，且按**写入前**的收藏状态区分措辞：
/// - 原本未收藏 → 「收藏失败，请重试」
/// - 原本已收藏 → 「取消喜欢失败，请重试」
///
/// ## 为什么本文件必须把窗口设成**竖屏**
///
/// 收藏按钮位于 `_buildHeader`，而 `_buildHeader` **只出现在竖屏布局**
/// （`_buildPortrait`）与「横屏显示歌词」布局中；
/// 默认横屏布局 `_buildLandscapeControls` 并不渲染头部。
/// flutter_test 默认画布 800×600 属横屏，因此必须先固定为竖屏尺寸，
/// 否则按钮根本不在树上（用例会以「找不到控件」的假失败收场）。
///
/// ## 分层：本文件不出现任何真实 Hive 写盘
///
/// 仓库用内存假实现（见 `library_page_test.dart` 顶部的分层说明：
/// `testWidgets` 的伪造时钟会让 Hive 真实写盘永不完成，测试挂起且
/// **没有断言失败**）。真实落盘语义由 `library_repository_test.dart`
/// 与 `test/e2e/main_flow_test.dart` 覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLibraryRepository repository;
  late Directory tempDir;
  late Box<String> settingsBox;

  setUpAll(() async {
    // 该 Box 只在 build 期间被**同步读取**（无 await），不触发挂起问题。
    tempDir = await Directory.systemTemp.createTemp('musaic_player_page');
    Hive.init(tempDir.path);
    settingsBox = await Hive.openBox<String>('pp_settings');
  });

  tearDownAll(() async {
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

  /// 无封面 URL：播放页的背景 / 大图 / 取色全部走占位分支，
  /// 因此本文件不产生任何网络请求。
  Track song(String id) => Track(
    id: id,
    sourceId: 'netease',
    title: '歌$id',
    artist: 'Beyond',
    duration: const Duration(minutes: 3),
  );

  Widget host() {
    _StubPlayerNotifier.initialState = PlayerState(
      queue: <Track>[song('1')],
      currentIndex: 0,
    );
    return ProviderScope(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repository),
        // 播放页会解析渠道徽标；注入空注册表，避免它沿组合根去要
        // accountRepository（未启动时必然抛错）。
        sourceRegistryProvider.overrideWithValue(SourceRegistry()),
        // 真实 AudioPlayer 在单元测试环境没有平台通道，任何调用都会挂起
        // ~25s 后超时，必须换成桩。
        audioHandlerProvider.overrideWithValue(
          MusaicAudioHandler(player: _StubPlayer()),
        ),
        appSettingsRepositoryProvider.overrideWithValue(
          AppSettingsRepository(box: settingsBox),
        ),
        playerNotifierProvider.overrideWith(_StubPlayerNotifier.new),
      ],
      child: MaterialApp(theme: AppTokens.darkTheme, home: const PlayerPage()),
    );
  }

  /// 竖屏画布 + 装配播放页。返回后可安全 tap 头部收藏按钮。
  Future<void> pumpPlayer(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
  }

  /// 点击头部收藏按钮并等 SnackBar 出现。
  ///
  /// 刻意**不用** `pumpAndSettle`：SnackBar 默认 4s 后自动消失，
  /// settle 会把提示一起等掉，断言随即找不到文案。
  Future<void> tapFavorite(WidgetTester tester) async {
    await tester.tap(find.byTooltip('喜欢'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('播放页收藏失败反馈（计划 3.3）', () {
    testWidgets('收藏写盘失败时给出「收藏失败，请重试」并记日志', (tester) async {
      repository.failToggleFavorite = true;
      await pumpPlayer(tester);

      await tapFavorite(tester);

      expect(
        find.text('收藏失败，请重试'),
        findsOneWidget,
        reason: '写盘失败必须给出可见提示，此前是静默冒泡、点下去毫无反应',
      );
      // 不得谎报成功
      expect(find.text('已加入喜欢'), findsNothing);
      // 失败必须留日志（AppLog），否则线上无从定位
      final messages = AppLog.records.map((r) => r.message).join('\n');
      expect(messages, contains('收藏写入失败'));
      expect(
        AppLog.records.any((r) => r.tag == 'MusaicLibrary'),
        isTrue,
        reason: '失败日志应带 MusaicLibrary 标签',
      );
    });

    testWidgets('取消收藏失败时措辞为「取消喜欢失败」，且不谎报成功', (tester) async {
      final target = song('1');
      repository
        ..seedFavorite(target)
        ..failToggleFavorite = true;
      await pumpPlayer(tester);

      await tapFavorite(tester);

      expect(
        find.text('取消喜欢失败，请重试'),
        findsOneWidget,
        reason: '措辞要按写入前的状态区分：原本已收藏是「取消」失败，不是「收藏」失败',
      );
      expect(find.text('收藏失败，请重试'), findsNothing);
      expect(find.text('已取消喜欢'), findsNothing);
    });

    testWidgets('成功路径仍提示「已加入喜欢」（守护 try/catch 未吞掉成功提示）', (tester) async {
      await pumpPlayer(tester);

      await tapFavorite(tester);

      expect(find.text('已加入喜欢'), findsOneWidget);
      expect(find.text('收藏失败，请重试'), findsNothing);
      expect(repository.toggleCalls, <String>[
        'netease:1',
      ], reason: '确认点击确实到达仓库，否则上面的成功断言可能来自别处');
    });
  });
}

/// 假仓库：只实现播放页用到的收藏读取/切换，其余成员显式抛错。
class _FakeLibraryRepository implements LibraryRepository {
  final List<Track> _favoriteTracks = <Track>[];

  /// 记录被切换过的 key，用于确认点击真的到达了仓库。
  final List<String> toggleCalls = <String>[];

  /// true 时 [toggleFavorite] 抛错（计划 3.3 失败反馈用例）。
  bool failToggleFavorite = false;

  void seedFavorite(Track track) => _favoriteTracks.add(track);

  @override
  List<Track> get favorites => List<Track>.of(_favoriteTracks);

  @override
  bool isFavorite(String trackKey) =>
      _favoriteTracks.any((t) => t.key == trackKey);

  @override
  Future<bool> toggleFavorite(Track track) async {
    toggleCalls.add(track.key);
    if (failToggleFavorite) {
      // 模拟写盘失败：必须在**改动内存之前**抛出，
      // 否则「失败后状态保持原样」的断言会被假仓库自己破坏。
      throw StateError('模拟收藏写盘失败');
    }
    final index = _favoriteTracks.indexWhere((t) => t.key == track.key);
    if (index >= 0) {
      _favoriteTracks.removeAt(index);
      return false;
    }
    _favoriteTracks.add(track);
    return true;
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
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('假仓库未实现：${invocation.memberName}');
}

/// 播放器桩：绕过真实解析链，直接给出「已有一首当前曲」的状态。
class _StubPlayerNotifier extends PlayerNotifier {
  static PlayerState initialState = const PlayerState();

  @override
  PlayerState build() => initialState;
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
