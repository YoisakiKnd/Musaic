import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/source_account.dart';
import '../core/di/app_providers.dart';
import '../features/auth/application/account_notifier.dart';
import '../features/auth/presentation/login_launcher.dart';
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
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasQueue = ref.watch(playerHasQueueProvider);

    // 登录过期全局引导：任一渠道「已登录 → 已过期」迁移时提示并可一键重登
    //（被动 401 捕获与启动后台校验共用此入口；每渠道只在迁移瞬间提醒一次）。
    ref.listen(accountsProvider, (previous, next) {
      if (previous == null) return;
      for (final entry in next.bySource.entries) {
        if (entry.value.status != AccountStatus.expired) continue;
        if (previous.bySource[entry.key]?.status != AccountStatus.loggedIn) {
          continue;
        }
        final source =
            ref.read(sourceRegistryProvider).resolve(entry.key);
        if (source == null) continue;
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${source.displayName} 登录已过期'),
            duration: const Duration(seconds: 6),
            action: SnackBarAction(
              label: '重新登录',
              onPressed: () => launchChannelLogin(context, ref, source),
            ),
          ),
        );
        break; // 一次只提醒一条
      }
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= AppTokens.compactBreakpoint;
        if (isWide) return _buildWide(context, hasQueue);
        return _buildCompact(context, hasQueue);
      },
    );
  }

  Widget _buildCompact(BuildContext context, bool hasQueue) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          Positioned.fill(child: navigationShell),
          if (hasQueue)
            const Positioned(
              left: 12,
              right: 12,
              bottom: 92,
              child: MiniPlayer(),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: NavigationBar(
            height: 64,
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            indicatorColor: AppTokens.accent.withValues(alpha: 0.15),
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
        ),
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
