import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:musaic/app/app_shell.dart';
import 'package:musaic/app/route_location.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/features/auth/application/account_notifier.dart';
import 'package:musaic/features/player/mini_player.dart';
import 'package:musaic/features/player/player_notifier.dart';

/// 播放失败提示的**全局可见性**（计划 2.2 / 用户层交互 U4）。
///
/// ## 修复前的缺陷
///
/// `PlayerState.error` 此前只有一个消费者：全屏播放页的 `_PlayerErrorBanner`。
/// 迷你条、首页、骨架（AppShell）都不读它。后果是——后台自动切歌失败时
/// （用户正在资料库或首页），界面上**没有任何变化**：进度条停住、没有声音、
/// 没有任何文字，用户只会以为「就是没声音」，不会想到进播放页看原因。
///
/// ## 本文件钉住的契约
///
/// 1. **非播放页**：错误出现时必须弹出全局提示，且提示里带「重试」动作；
/// 2. **播放页**：必须**不**弹全局提示——播放页自身已有错误横幅
///    （可重试/可关闭），不避让会让同一次失败提示两遍；
/// 3. **迷你条**：错误必须可见（文案 + 错误色），否则「有队列但没声音」
///    依然无从判断。
///
/// 第 2 条依赖 [isOnPlayerRoute] 能真正识别被 `push` 的播放页——`/player`
/// 只通过 push 到达，而 go_router 的 `RouteMatchList.uri` **不反映**
/// `ImperativeRouteMatch`，用 `.uri` 判断会永远得到「不在播放页」。
/// 因此下面单列一组用例直接守护该判断函数。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const errorText = '获取播放地址失败：网络异常';

  Track song(String id) => Track(
    id: id,
    sourceId: 'fake',
    title: 't$id',
    artist: 'a',
    duration: const Duration(seconds: 30),
  );

  /// 可控播放器桩：直接给出初始状态，并可后续改写 error。
  ///
  /// 覆盖 `build()` 因此不会读取 `appSettingsRepositoryProvider`，
  /// 也不会触碰 `audioHandler`（单元测试环境没有 just_audio 平台通道）。
  /// 队列为空时 `retry()` 会立即早返回，所以点「重试」是安全 no-op。
  ProviderContainer shellContainer({
    required _StubPlayerNotifier notifier,
    required GoRouter router,
  }) {
    return ProviderContainer(
      overrides: [
        playerNotifierProvider.overrideWith(() => notifier),
        accountsProvider.overrideWith(_StubAccountNotifier.new),
      ],
    );
  }

  /// 与真实路由同构的最小路由：骨架 + 一个分支 + 根导航器上的播放页。
  /// 每次新建 navigatorKey，避免 GlobalKey 跨用例复用冲突。
  GoRouter buildRouter(GlobalKey<NavigatorState> key) => GoRouter(
    navigatorKey: key,
    initialLocation: '/home',
    routes: [
      StatefulShellRoute.indexedStack(
        builder:
            (context, state, navigationShell) =>
                AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home',
                builder: (_, _) => const Scaffold(body: Text('HOME')),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: playerRoutePath,
        parentNavigatorKey: key,
        builder: (_, _) => const Scaffold(body: Text('PLAYER')),
      ),
    ],
  );

  Future<void> pumpShell(
    WidgetTester tester,
    ProviderContainer container,
    GoRouter router,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('isOnPlayerRoute 能识别被 push 的播放页', () {
    testWidgets('停在 /home 时为 false', (tester) async {
      final key = GlobalKey<NavigatorState>();
      final router = buildRouter(key);
      final container = shellContainer(
        notifier: _StubPlayerNotifier(),
        router: router,
      );
      addTearDown(() {
        container.dispose();
        router.dispose();
      });

      await pumpShell(tester, container, router);

      expect(isOnPlayerRoute(router), isFalse);
    });

    testWidgets('push 到 /player 后为 true（.uri 判断会失败，此函数不会）', (tester) async {
      final key = GlobalKey<NavigatorState>();
      final router = buildRouter(key);
      final container = shellContainer(
        notifier: _StubPlayerNotifier(),
        router: router,
      );
      addTearDown(() {
        container.dispose();
        router.dispose();
      });

      await pumpShell(tester, container, router);

      unawaited(router.push(playerRoutePath));
      await tester.pumpAndSettle();

      expect(find.text('PLAYER'), findsOneWidget);
      // 前置事实：go_router 的 uri 不反映 imperative push，所以不能用它判断。
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        isNot(playerRoutePath),
        reason: '若这里变成 /player，说明 go_router 行为已变，判断实现可简化',
      );
      expect(isOnPlayerRoute(router), isTrue);
    });
  });

  group('非播放页必须弹出全局播放失败提示', () {
    testWidgets('错误出现时弹出 SnackBar 且带「重试」动作', (tester) async {
      final key = GlobalKey<NavigatorState>();
      final router = buildRouter(key);
      final notifier = _StubPlayerNotifier();
      final container = shellContainer(notifier: notifier, router: router);
      addTearDown(() {
        container.dispose();
        router.dispose();
      });

      await pumpShell(tester, container, router);

      expect(find.byType(SnackBar), findsNothing, reason: '初始无错误不应有提示');

      notifier.debugSetError(errorText);
      await tester.pumpAndSettle();

      expect(
        find.text(errorText),
        findsOneWidget,
        reason: '后台播放失败必须让用户看见，而不是只在播放页可见',
      );
      expect(
        find.widgetWithText(SnackBarAction, '重试'),
        findsOneWidget,
        reason: '只告知不给出口，用户无法恢复播放',
      );
    });

    testWidgets('点「重试」触发 notifier.retry（空队列下安全早返回）', (tester) async {
      final key = GlobalKey<NavigatorState>();
      final router = buildRouter(key);
      final notifier = _StubPlayerNotifier();
      final container = shellContainer(notifier: notifier, router: router);
      addTearDown(() {
        container.dispose();
        router.dispose();
      });

      await pumpShell(tester, container, router);
      notifier.debugSetError(errorText);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(SnackBarAction, '重试'));
      await tester.pumpAndSettle();

      expect(notifier.retryCalls, 1, reason: '「重试」必须真的接到 notifier.retry');
    });
  });

  group('播放页必须避让，避免同一次失败提示两遍', () {
    testWidgets('在 /player 上错误出现时不弹全局 SnackBar', (tester) async {
      final key = GlobalKey<NavigatorState>();
      final router = buildRouter(key);
      final notifier = _StubPlayerNotifier();
      final container = shellContainer(notifier: notifier, router: router);
      addTearDown(() {
        container.dispose();
        router.dispose();
      });

      await pumpShell(tester, container, router);

      unawaited(router.push(playerRoutePath));
      await tester.pumpAndSettle();
      expect(isOnPlayerRoute(router), isTrue);

      notifier.debugSetError(errorText);
      await tester.pumpAndSettle();

      expect(
        find.byType(SnackBar),
        findsNothing,
        reason: '播放页自身已有错误横幅，全局再弹一次就是重复提示',
      );
    });
  });

  group('迷你条必须显示播放失败标记', () {
    Future<void> pumpMini(
      WidgetTester tester,
      _StubPlayerNotifier notifier,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [playerNotifierProvider.overrideWith(() => notifier)],
          child: const MaterialApp(home: Scaffold(body: MiniPlayer())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('有错误时显示「播放失败，点击查看」与错误图标', (tester) async {
      final notifier = _StubPlayerNotifier(
        initial: PlayerState(
          queue: [song('1')],
          currentIndex: 0,
          error: errorText,
        ),
      );

      await pumpMini(tester, notifier);

      expect(find.text('播放失败，点击查看'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expect(
        find.text(errorText),
        findsNothing,
        reason: '迷你条空间有限，只给可读的短文案，完整原因留给播放页',
      );
    });

    testWidgets('无错误时显示正常的歌手信息（不误报）', (tester) async {
      final notifier = _StubPlayerNotifier(
        initial: PlayerState(queue: [song('1')], currentIndex: 0),
      );

      await pumpMini(tester, notifier);

      expect(find.text('播放失败，点击查看'), findsNothing);
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
      expect(find.text('a'), findsOneWidget);
    });
  });
}

/// 播放器桩：可控初始状态 + 记录 retry 调用次数。
class _StubPlayerNotifier extends PlayerNotifier {
  _StubPlayerNotifier({PlayerState initial = const PlayerState()})
    : _initial = initial;

  final PlayerState _initial;

  int retryCalls = 0;

  @override
  PlayerState build() => _initial;

  void debugSetError(String? message) {
    state = state.copyWith(error: message);
  }

  @override
  Future<void> retry() async {
    retryCalls++;
    // 不调用 super：真实实现会走 _loadAndPlay → audioHandler，
    // 而单元测试环境没有 just_audio 平台通道。
  }
}

/// 账号桩：覆盖 build() 以避免读取 accountRepositoryProvider
/// （真实实现会在 build 里恢复凭据并发起后台校验）。
class _StubAccountNotifier extends AccountNotifier {
  @override
  AccountsState build() => const AccountsState();
}
