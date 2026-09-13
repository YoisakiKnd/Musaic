import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/theme/app_tokens.dart';
import 'package:musaic/features/library/data/library_repository.dart';
import 'package:musaic/features/lyrics/application/lyrics_provider.dart';
import 'package:musaic/features/player/audio_handler.dart';
import 'package:musaic/features/player/player_notifier.dart';
import 'package:musaic/features/player/player_page.dart';
import 'package:musaic/features/settings/settings_providers.dart';

/// 横屏右侧区域「歌词 ↔ 控件」点击切换回归测试。
///
/// ## 固化的行为
///
/// 横屏右侧此前只能由持久化设置「横屏右侧显示歌词」决定：正在看歌词时想
/// 调音量/切歌，必须退出播放页去设置里改。现在右侧整块区域可点击切换：
/// - 初值仍取该设置（未点击时与改动前完全一致）；
/// - 点击切换，且**不写回设置**（临时查看，不是偏好变更）；
/// - 退出沉浸模式清掉本次临时结果，回到设置决定的状态；
/// - 切换只影响右侧内容，不改变播放状态与进度，控件绑定不丢失。
///
/// ## 判据为什么不用 PlayerControls
///
/// `PlayerControls` 在**两个**横屏布局里都存在（左侧列各有一份），因此
/// 它无法区分当前是哪一态。可靠的判据是 [_LandscapeSideTapTarget] 暴露的
/// Semantics hint：控件态时提示「点击切换到歌词」，歌词态时提示
/// 「点击切换到控件」——它直接反映当前渲染的是哪个分支。
///
/// ## 分层
///
/// 与同目录 `player_page_test.dart` 一致：内存假仓库 + 桩播放器。
/// 涉及真实 Hive 写盘的地方必须走 [WidgetTester.runAsync]——`testWidgets`
/// 的伪造时钟下真实落盘永不完成，会以「测试跑完但不结束」的形式挂起，
/// 且没有任何断言失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLibraryRepository repository;
  late Directory tempDir;
  late Box<String> settingsBox;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_landscape_side');
    Hive.init(tempDir.path);
    settingsBox = await Hive.openBox<String>('ls_settings');
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

  setUp(() async {
    repository = _FakeLibraryRepository();
    // 每个用例从「设置关闭」开始：默认右侧为控件态。
    await settingsBox.clear();
    _StubPlayerNotifier.resetCounters();
  });

  Track song(String id) => Track(
    id: id,
    sourceId: 'netease',
    title: '歌$id',
    artist: 'Beyond',
    duration: const Duration(minutes: 3),
  );

  /// [hasLyrics] 为 false 时歌词源返回 null（渠道明确表示无歌词）。
  Widget host({bool hasLyrics = true, LyricBundle? lyrics}) {
    _StubPlayerNotifier.initialState = PlayerState(
      queue: <Track>[song('1')],
      currentIndex: 0,
    );
    return ProviderScope(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repository),
        sourceRegistryProvider.overrideWithValue(SourceRegistry()),
        audioHandlerProvider.overrideWithValue(
          MusaicAudioHandler(player: _StubPlayer()),
        ),
        appSettingsRepositoryProvider.overrideWithValue(
          AppSettingsRepository(box: settingsBox),
        ),
        playerNotifierProvider.overrideWith(_StubPlayerNotifier.new),
        // 直接给出歌词，避免依赖渠道解析。
        lyricsProvider.overrideWith(
          (ref, track) async =>
              hasLyrics ? (lyrics ?? _bundle('第一行歌词', '第二行歌词')) : null,
        ),
      ],
      child: MaterialApp(theme: AppTokens.darkTheme, home: const PlayerPage()),
    );
  }

  /// 横屏画布 + 装配播放页。
  ///
  /// [landscapeLyrics] 为 true 时先把设置「横屏右侧显示歌词」写为 true。
  Future<void> pumpLandscape(
    WidgetTester tester, {
    bool landscapeLyrics = false,
    bool hasLyrics = true,
    LyricBundle? lyrics,
  }) async {
    if (landscapeLyrics) {
      // 必须走真实时钟，否则 Hive 写盘在伪造时钟下永不完成。
      await tester.runAsync(() => settingsBox.put('landscape_lyrics', 'true'));
    }
    // flutter_test 默认画布 800×600 恰为横屏，但显式固定尺寸更可靠。
    tester.view.physicalSize = const Size(900, 450);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(hasLyrics: hasLyrics, lyrics: lyrics));
    // 不用 pumpAndSettle：进度条等控件存在持续动画，settle 会超时。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 当前右侧区域暴露的切换提示，直接反映渲染的是哪个分支。
  ///
  /// 这是唯一可靠的判据：`PlayerControls` 在两个横屏布局里都存在，
  /// 无法区分状态；而切换外壳的 Semantics hint 与分支一一对应。
  String? sideHint() {
    for (final element in find.byType(Semantics).evaluate()) {
      final hint = (element.widget as Semantics).properties.hint;
      if (hint == '点击切换到歌词' || hint == '点击切换到控件') return hint;
    }
    return null;
  }

  /// 当前右侧是否为歌词态（提示指向控件 + 歌词文本已渲染）。
  bool isLyricsSide() =>
      sideHint() == '点击切换到控件' && find.text('第一行歌词').evaluate().isNotEmpty;

  /// 当前右侧是否为控件态（提示指向歌词 + 歌词文本未出现）。
  bool isControlsSide() =>
      sideHint() == '点击切换到歌词' && find.text('第一行歌词').evaluate().isEmpty;

  /// 点击右侧区域的空白处（避开内部按钮与滑杆）。
  ///
  /// 沉浸模式下功能行隐藏，右下角是空白区，命中切换外壳本身。
  Future<void> tapRightSide(WidgetTester tester) async {
    final page = tester.getRect(find.byType(PlayerPage));
    await tester.tapAt(Offset(page.right - 40, page.bottom - 40));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('横屏右侧点击切换（歌词 ↔ 控件）', () {
    testWidgets('默认（设置关闭）：右侧显示控件，不显示歌词', (tester) async {
      await pumpLandscape(tester);

      expect(
        isControlsSide(),
        isTrue,
        reason: '设置 landscape_lyrics 未开启时，右侧应为控件态（与改动前一致）',
      );
      expect(find.text('第一行歌词'), findsNothing);
    });

    testWidgets('设置开启时初值仍为歌词态（不改变既有设置语义）', (tester) async {
      await pumpLandscape(tester, landscapeLyrics: true);

      expect(
        isLyricsSide(),
        isTrue,
        reason: '「横屏右侧显示歌词」开启时初值必须是歌词，否则改动破坏了原有设置',
      );
    });

    testWidgets('点击右侧空白：控件态 → 歌词态', (tester) async {
      await pumpLandscape(tester);
      expect(isControlsSide(), isTrue);

      await tapRightSide(tester);

      expect(isLyricsSide(), isTrue, reason: '点击右侧区域应切到歌词态');
    });

    testWidgets('再次点击：歌词态 → 控件态', (tester) async {
      await pumpLandscape(tester, landscapeLyrics: true);
      expect(isLyricsSide(), isTrue);

      await tapRightSide(tester);
      expect(isControlsSide(), isTrue, reason: '第二次点击应切回控件态');
    });

    testWidgets('切回控件后原有控件仍可用（绑定未丢失）', (tester) async {
      await pumpLandscape(tester, landscapeLyrics: true);
      expect(isLyricsSide(), isTrue);

      await tapRightSide(tester);
      expect(isControlsSide(), isTrue);

      // 随机播放按钮仍能真正调用到 notifier。
      await tester.tap(find.byTooltip('随机播放'));
      await tester.pump();
      expect(
        _StubPlayerNotifier.shuffleToggles,
        1,
        reason: '切换只改显示，不得让控件丢绑定——随机播放必须仍然生效',
      );
    });

    testWidgets('切换不改变播放状态与进度（只改右侧内容）', (tester) async {
      await pumpLandscape(tester);
      expect(isControlsSide(), isTrue);

      await tapRightSide(tester);
      expect(isLyricsSide(), isTrue);
      await tapRightSide(tester);
      expect(isControlsSide(), isTrue);

      expect(
        _StubPlayerNotifier.playbackMutatingCalls,
        0,
        reason: '切换不得触发播放/暂停/切歌/拖动等任何改变播放状态的操作',
      );
    });

    testWidgets('点击切换不写回设置（临时查看，不改偏好）', (tester) async {
      await pumpLandscape(tester);
      expect(settingsBox.get('landscape_lyrics'), isNull);

      await tapRightSide(tester);
      expect(isLyricsSide(), isTrue);

      expect(
        settingsBox.get('landscape_lyrics'),
        isNull,
        reason: '点击是临时查看，不得把设置项写成 true',
      );
    });

    testWidgets('退出沉浸模式后清掉临时切换，回到设置决定的状态', (tester) async {
      // 设置关闭 → 点成歌词态 → 退出沉浸模式 → 应回到控件态。
      await pumpLandscape(tester);
      expect(isControlsSide(), isTrue);

      await tapRightSide(tester);
      expect(isLyricsSide(), isTrue);

      await tester.tap(find.byTooltip('退出沉浸模式'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(isControlsSide(), isTrue, reason: '退出沉浸模式应清掉本次点击的临时结果，回到设置决定的状态');
    });

    testWidgets('无歌词时显示占位内容，不留空白也不报错', (tester) async {
      await pumpLandscape(tester, landscapeLyrics: true, hasLyrics: false);

      expect(find.text('暂无歌词'), findsOneWidget, reason: '无歌词要显示占位文案，不能留空白');
      expect(tester.takeException(), isNull, reason: '无歌词不得抛异常');
    });
  });
}

/// 构造两行歌词，用于以可见文本判定「当前是歌词态」。
LyricBundle _bundle(String first, String second) => LyricBundle(
  lines: <LyricLine>[
    LyricLine(text: first, start: Duration.zero),
    LyricLine(text: second, start: const Duration(seconds: 3)),
  ],
);

/// 假仓库：播放页只用收藏读取/切换，其余显式抛错。
class _FakeLibraryRepository implements LibraryRepository {
  final List<Track> _favoriteTracks = <Track>[];

  @override
  List<Track> get favorites => List<Track>.of(_favoriteTracks);

  @override
  bool isFavorite(String trackKey) =>
      _favoriteTracks.any((t) => t.key == trackKey);

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

/// 播放器桩：记录「会改变播放状态」的调用次数，用于验证切换不干扰播放。
class _StubPlayerNotifier extends PlayerNotifier {
  static PlayerState initialState = const PlayerState();
  static int shuffleToggles = 0;
  static int playbackMutatingCalls = 0;

  static void resetCounters() {
    shuffleToggles = 0;
    playbackMutatingCalls = 0;
  }

  @override
  PlayerState build() {
    resetCounters();
    return initialState;
  }

  @override
  void toggleShuffle() {
    shuffleToggles++;
  }

  // 以下都算「改变播放状态/进度」，切换过程中必须一次都不被调用。
  @override
  Future<void> toggle() async => playbackMutatingCalls++;

  @override
  Future<void> next() async => playbackMutatingCalls++;

  @override
  Future<void> previous() async => playbackMutatingCalls++;

  @override
  Future<void> seekTo(Duration position) async => playbackMutatingCalls++;

  @override
  Future<void> setVolume(double value) async => playbackMutatingCalls++;
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
