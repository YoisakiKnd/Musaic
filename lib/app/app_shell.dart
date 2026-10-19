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
import 'route_location.dart';

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

    // 播放失败的全局提示（U4）：错误此前**只在全屏播放页可见**，后台自动
    // 切歌失败时用户毫无感知（迷你条也不显示）。这里在非播放页补一条全局
    // 提示；播放页自身已有错误横幅（可重试/关闭），必须避让，否则同一次
    // 失败会弹两条。
    ref.listen(playerNotifierProvider.select((s) => s.error), (_, next) {
      if (next == null) return;
      final router = GoRouter.maybeOf(context);
      if (router != null && isOnPlayerRoute(router)) return;
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(next),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: '重试',
            onPressed: () => ref.read(playerNotifierProvider.notifier).retry(),
          ),
        ),
      );
    });

    // 播放提示（换源 / 仅试听片段）：后台自动切歌时用户多半不在播放页，
    // 此前提示只在播放页弹出，会一直积压到下次打开播放页才冒出来。
    ref.listen(playerNotifierProvider.select((s) => s.notice), (_, next) {
      if (next == null) return;
      final router = GoRouter.maybeOf(context);
      if (router != null && isOnPlayerRoute(router)) return; // 播放页自己弹
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next)));
      ref.read(playerNotifierProvider.notifier).clearNotice();
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= AppTokens.compactBreakpoint;
        if (isWide) return _buildWide(context, hasQueue);
        return _buildCompact(context, hasQueue);
      },
    );
  }

  /// 切换栏目；再点一次当前栏目则回到该栏目首页。
  ///
  /// `goBranch(initialLocation: true)` 只重置路由表里的页面，弹不掉在分支
  /// 导航器里命令式 push 的页面（搜索结果、云端歌单）——此前在搜索结果页
  /// 点「搜索」毫无反应，只能按返回键。
  void _selectDestination(int index) {
    if (index == navigationShell.currentIndex) {
      navigationShell.route.branches[index].navigatorKey.currentState?.popUntil(
        (route) => route.isFirst,
      );
    }
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
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
            onDestinationSelected: _selectDestination,
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
            onDestinationSelected: _selectDestination,
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
