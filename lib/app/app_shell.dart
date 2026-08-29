import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/source_account.dart';
import '../core/di/app_providers.dart';
import '../core/theme/app_tokens.dart';
import '../features/auth/application/account_notifier.dart';
import '../features/auth/presentation/login_launcher.dart';
import '../features/player/mini_player.dart';
import '../features/player/player_notifier.dart';

/// 自适应骨架（Master Plan §8）：
/// - < 840dp：全宽底部导航（MiniPlayer 贴于导航上方，方角）
/// - >= 840dp：NavigationRail（MiniPlayer 作为底部全宽条）
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
        final source = ref.read(sourceRegistryProvider).resolve(entry.key);
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
    return Scaffold(
      body: navigationShell,
      // 传统 Material：标准全宽 NavigationBar（无圆角、无悬浮边框），
      // MiniPlayer 作为方角条直接贴在导航上方
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasQueue) const MiniPlayer(),
          NavigationBar(
            height: 76,
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected:
                (index) => navigationShell.goBranch(
                  index,
                  initialLocation: index == navigationShell.currentIndex,
                ),
            destinations: [
              for (final (icon, label) in _destinations)
                NavigationDestination(
                  icon: Icon(icon),
                  selectedIcon: Icon(icon),
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
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected:
                (index) => navigationShell.goBranch(
                  index,
                  initialLocation: index == navigationShell.currentIndex,
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
                child: const Icon(
                  Icons.graphic_eq_rounded,
                  size: 20,
                  color: Colors.white,
                ),
              ),
            ),
            destinations: [
              for (final (icon, label) in _destinations)
                NavigationRailDestination(
                  icon: Icon(icon),
                  selectedIcon: Icon(icon),
                  label: Text(label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: navigationShell),
        ],
      ),
      bottomNavigationBar: hasQueue ? const MiniPlayer() : null,
    );
  }
}

/// 队列是否存在的选择器（驱动 MiniPlayer 显隐）。
final playerHasQueueProvider = Provider<bool>(
  (ref) => ref.watch(playerNotifierProvider.select((s) => s.hasQueue)),
);
