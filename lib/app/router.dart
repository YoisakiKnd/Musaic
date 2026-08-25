import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_tokens.dart';
import '../features/auth/presentation/account_center.dart';
import '../features/home/home_page.dart';
import '../features/library/library_page.dart';
import '../features/library/playlist_detail_page.dart';
import '../features/player/player_page.dart';
import '../features/search/search_page.dart';
import 'app_shell.dart';

final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');

/// 路由表：四 Tab StatefulShell + 全屏播放器 + 歌单详情。
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/home',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home',
                builder: (_, _) => const HomePage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/search',
                builder: (_, _) => const SearchPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/library',
                builder: (_, _) => const LibraryPage(),
              ),
              GoRoute(
                path: '/playlist/:name',
                builder: (context, state) => PlaylistDetailPage(
                  name: Uri.decodeComponent(
                    state.pathParameters['name'] ?? '',
                  ),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/account',
                builder: (_, _) => const AccountCenterPage(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/player',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => CustomTransitionPage<void>(
          key: state.pageKey,
          child: const PlayerPage(),
          transitionDuration: AppTokens.durationSlow,
          reverseTransitionDuration: AppTokens.durationNormal,
          transitionsBuilder: (context, animation, _, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: AppTokens.curveEmphasized,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.06),
                end: Offset.zero,
              ).animate(curved),
              child: FadeTransition(opacity: curved, child: child),
            );
          },
        ),
      ),
    ],
  );
});
