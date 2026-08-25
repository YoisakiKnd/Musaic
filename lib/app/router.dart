import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musaic/features/home/home_page.dart';
import 'package:musaic/features/search/search_page.dart';
import 'package:musaic/features/library/library_page.dart';
import 'package:musaic/features/library/playlist_detail_page.dart';
import 'package:musaic/features/auth/account_page.dart';
import 'package:musaic/app/app_shell.dart';

final goRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    debugLogDiagnostics: true,
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/', builder: (context, state) => const HomePage()),
          GoRoute(path: '/search', builder: (context, state) => const SearchPage()),
          GoRoute(path: '/library', builder: (context, state) => const LibraryPage()),
          GoRoute(
            path: '/playlist/:playlistId',
            builder: (context, state) {
              final playlistId = state.pathParameters['playlistId']!;
              return PlaylistDetailPage(playlistId: playlistId);
            },
          ),
          GoRoute(path: '/account', builder: (context, state) => const AccountPage()),
        ],
      ),
    ],
  );
});
