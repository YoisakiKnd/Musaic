import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';
import 'package:musaic/app/widgets/side_nav.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/theme/app_tokens.dart';
import 'package:musaic/features/library/data/library_providers.dart';
import 'package:musaic/features/player/audio_handler.dart';
import 'package:musaic/features/player/now_playing_bar.dart';
import 'package:musaic/features/player/open_player.dart';
import 'package:musaic/features/player/player_notifier.dart';
import 'package:musaic/features/player/widgets/player_controls.dart';

/// 全平台适配后的播放相关契约：
/// 1. 平板 / 桌面的底部播放条可用，窄窗口收起音量滑条；
/// 2. 只有手机点歌会进入全屏播放页，宽屏留在列表里；
/// 3. 播放进度变化不得让控制按钮重建（性能回归）；
/// 4. 桌面侧边栏列出歌单并可直接打开。
void main() {
  const track = Track(
    id: '1',
    sourceId: 'netease',
    title: '海阔天空',
    artist: 'Beyond',
    duration: Duration(minutes: 5),
  );

  late _StubPlayerNotifier notifier;

  setUp(() {
    notifier = _StubPlayerNotifier(
      const PlayerState(queue: [track], currentIndex: 0),
    );
  });

  void setWidth(WidgetTester tester, double width) {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  List<Override> overrides() => [
    playerNotifierProvider.overrideWith(() => notifier),
    audioHandlerProvider.overrideWithValue(
      MusaicAudioHandler(player: _StubPlayer()),
    ),
    sourceRegistryProvider.overrideWithValue(SourceRegistry()),
    isFavoriteProvider.overrideWith((ref, track) => false),
  ];

  Widget host(Widget child) => ProviderScope(
    overrides: overrides(),
    child: MaterialApp(
      theme: AppTokens.darkTheme,
      home: Scaffold(bottomNavigationBar: child),
    ),
  );

  group('底部播放条', () {
    testWidgets('宽窗口：曲目信息、完整控制、队列与音量', (tester) async {
      setWidth(tester, 1280);
      await tester.pumpWidget(host(const NowPlayingBar()));

      expect(find.text('海阔天空'), findsOneWidget);
      expect(find.byTooltip('上一首'), findsOneWidget);
      expect(find.byTooltip('下一首'), findsOneWidget);
      expect(find.byTooltip('播放队列'), findsOneWidget);
      expect(find.byTooltip('静音'), findsOneWidget);
      expect(find.text('5:00'), findsOneWidget, reason: '总时长');
    });

    testWidgets('较窄窗口收起音量滑条，不溢出', (tester) async {
      setWidth(tester, 700);
      await tester.pumpWidget(host(const NowPlayingBar()));

      expect(find.byTooltip('静音'), findsNothing);
      expect(find.byTooltip('播放队列'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('没有正在播放的曲目时不占位', (tester) async {
      notifier = _StubPlayerNotifier(const PlayerState());
      setWidth(tester, 1280);
      await tester.pumpWidget(host(const NowPlayingBar()));

      expect(find.byType(PlayerControls), findsNothing);
    });
  });

  testWidgets('播放进度变化不让控制按钮重建（只有进度条重建）', (tester) async {
    setWidth(tester, 1280);
    await tester.pumpWidget(host(const NowPlayingBar()));

    notifier.tick(const Duration(seconds: 42));

    // Riverpod 在状态变化时同步标脏订阅者；select 过滤后控制区不应被标脏
    expect(tester.element(find.byType(PlayerControls)).dirty, isFalse);
    expect(tester.element(find.byType(PlayPauseButton)).dirty, isFalse);
    await tester.pump();
    expect(find.text('0:42'), findsOneWidget, reason: '进度条照常刷新');
  });

  group('点歌后是否进入播放页', () {
    Future<GoRouter> pumpRouter(WidgetTester tester) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder:
                (context, _) => Scaffold(
                  body: TextButton(
                    onPressed: () => openPlayerAfterPlay(context),
                    child: const Text('播放'),
                  ),
                ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, _) => const Scaffold(body: Text('播放页')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      return router;
    }

    testWidgets('手机：进入全屏播放页', (tester) async {
      setWidth(tester, 400);
      await pumpRouter(tester);
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      expect(find.text('播放页'), findsOneWidget);
    });

    testWidgets('平板 / 桌面：留在当前页（底部播放条可见）', (tester) async {
      setWidth(tester, 1280);
      await pumpRouter(tester);
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      expect(find.text('播放页'), findsNothing);
    });
  });

  testWidgets('侧边栏列出本地歌单，点击在当前栏目打开', (tester) async {
    setWidth(tester, 1280);
    Widget? opened;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides(),
          playlistsProvider.overrideWith((ref) => Stream.value(['通勤'])),
        ],
        child: MaterialApp(
          theme: AppTokens.darkTheme,
          home: Scaffold(
            body: Row(
              children: [
                SideNav(
                  selectedIndex: 0,
                  destinations: const [
                    (Icons.home_outlined, Icons.home_rounded, '首页'),
                  ],
                  onSelect: (_) {},
                  onOpenPage: (page) => opened = page,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('首页'), findsOneWidget);
    expect(find.text('我喜欢的音乐'), findsOneWidget);
    await tester.tap(find.text('通勤'));
    expect(opened, isNotNull);
  });
}

class _StubPlayerNotifier extends PlayerNotifier {
  _StubPlayerNotifier(this._initial);

  final PlayerState _initial;

  @override
  PlayerState build() => _initial;

  void tick(Duration position) {
    state = state.copyWith(position: position, duration: state.duration);
  }
}

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
  Future<void> dispose() async {}
}
