import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/settings/settings_page.dart';
import '../features/home/home_page.dart';
import '../features/library/library_page.dart';
import '../features/library/playlist_detail_page.dart';
import '../features/player/player_page.dart';
import '../features/search/search_page.dart';
import '../core/utils/nav_intent.dart';
import 'app_shell.dart';
import 'route_location.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'root',
);

/// 路由表：四 Tab StatefulShell + 全屏播放器 + 歌单详情。
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/home',
    routes: [
      StatefulShellRoute.indexedStack(
        builder:
            (context, state, navigationShell) =>
                AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/home', builder: (_, _) => const HomePage()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/search',
                // 外部请求（TrackTile 点艺人 / 首页快捷入口）经 extra 传入；
                // 用户点底部 Tab 进来时 extra 为 null → 只显示历史，不自动搜索
                builder:
                    (_, state) => SearchPage(
                      queryIntent: navIntentOf<String>(state.extra),
                    ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/library',
                // 首页快捷入口可指定初始 Tab（0 喜欢 / 1 最近播放 / 2 歌单）；
                // 底部 Tab 直接进入时为 null → 落在默认的「喜欢」
                builder:
                    (_, state) => LibraryPage(
                      initialTabIntent: navIntentOf<int>(state.extra),
                    ),
              ),
              GoRoute(
                path: '/playlist/:name',
                builder:
                    (context, state) => PlaylistDetailPage(
                      name: Uri.decodeComponent(
                        state.pathParameters['name'] ?? '',
                      ),
                    ),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/settings',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, _) => const SettingsPage(),
      ),
      // 播放页：Apple Music 式模态——自底整幅上滑打开，pop 时下滑关闭；
      // opaque=false 让底层页面在转场中保持可见并压暗
      GoRoute(
        path: playerRoutePath,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder:
            (context, state) => CustomTransitionPage<void>(
              key: state.pageKey,
              child: const PlayerPage(),
              transitionDuration: const Duration(milliseconds: 380),
              reverseTransitionDuration: const Duration(milliseconds: 300),
              opaque: false,
              barrierColor: Colors.black,
              transitionsBuilder: (context, animation, _, child) {
                final curved = CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                );
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 1),
                    end: Offset.zero,
                  ).animate(curved),
                  child: child,
                );
              },
            ),
      ),
    ],
  );
});
