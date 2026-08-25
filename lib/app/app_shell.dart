import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_tokens.dart';
import '../features/player/mini_player.dart';
import '../features/player/player_notifier.dart';

/// 自适应骨架（Master Plan §8）：
/// - < 840dp：底部导航（MiniPlayer 悬浮其上）
/// - >= 840dp：NavigationRail（MiniPlayer 底部居中悬浮）
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const _destinations = <(IconData, String)>[
    (Icons.home_rounded, '首页'),
    (Icons.search_rounded, '搜索'),
    (Icons.library_music_rounded, '资料库'),
    (Icons.person_rounded, '账号'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasQueue = ref.watch(playerHasQueueProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= AppTokens.compactBreakpoint;
        if (isWide) return _buildWide(context, hasQueue);
        return _buildCompact(context, hasQueue);
      },
    );
  }

  Widget _buildCompact(BuildContext context, bool hasQueue) {
    return Scaffold(
      extendBody: true,
      body: navigationShell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasQueue)
            const Padding(
              padding: EdgeInsets.only(bottom: 2),
              child: MiniPlayer(),
            ),
          NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: (index) => navigationShell.goBranch(
              index,
              initialLocation: index == navigationShell.currentIndex,
            ),
            destinations: [
              for (final (icon, label) in _destinations)
                NavigationDestination(
                  icon: Icon(icon),
                  selectedIcon: Icon(icon, color: AppTokens.accent),
                  label: label,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWide(BuildContext context, bool hasQueue) {
    return Scaffold(
      body: Stack(
        children: [
          Row(
            children: [
              NavigationRail(
                selectedIndex: navigationShell.currentIndex,
                onDestinationSelected: (index) => navigationShell.goBranch(
                  index,
                  initialLocation:
                      index == navigationShell.currentIndex,
                ),
                labelType: NavigationRailLabelType.all,
                leading: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(
                      gradient: AppTokens.brandGradient,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.graphic_eq_rounded,
                        size: 20, color: Colors.white),
                  ),
                ),
                destinations: [
                  for (final (icon, label) in _destinations)
                    NavigationRailDestination(
                      icon: Icon(icon),
                      selectedIcon: Icon(icon, color: AppTokens.accent),
                      label: Text(label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: navigationShell),
            ],
          ),
          if (hasQueue)
            Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: const MiniPlayer(),
              ),
            ),
        ],
      ),
    );
  }
}

/// 队列是否存在的选择器（驱动 MiniPlayer 显隐）。
final playerHasQueueProvider = Provider<bool>(
  (ref) => ref.watch(playerNotifierProvider.select((s) => s.hasQueue)),
);
