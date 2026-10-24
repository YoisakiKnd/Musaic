import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/source_account.dart';
import '../core/di/app_providers.dart';
import '../core/theme/app_tokens.dart';
import '../features/auth/application/account_notifier.dart';
import '../features/auth/presentation/login_launcher.dart';
import '../features/player/mini_player.dart';
import '../features/player/now_playing_bar.dart';
import '../features/player/player_notifier.dart';
import 'route_location.dart';
import 'widgets/side_nav.dart';

/// 自适应骨架（Material 3 窗口尺寸类）：
/// - < 600：手机——底部导航 + 悬浮迷你播放条，点开全屏播放页；
/// - 600–1024：平板 / 小窗口——导航栏轨 + 底部完整播放条；
/// - >= 1024：桌面 / 大屏——侧边栏（含歌单快捷入口）+ 底部完整播放条。
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const _destinations = <(IconData, IconData, String)>[
    (Icons.home_outlined, Icons.home_rounded, '首页'),
    (Icons.search_rounded, Icons.saved_search_rounded, '搜索'),
    (Icons.library_music_outlined, Icons.library_music_rounded, '资料库'),
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
        final width = constraints.maxWidth;
        if (width >= AppTokens.expandedBreakpoint) {
          return _buildExpanded(context, hasQueue);
        }
        if (width >= AppTokens.mediumBreakpoint) {
          return _buildMedium(context, hasQueue);
        }
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

  /// 在当前栏目的导航器里打开页面（侧边栏歌单用）：侧边栏与播放条保持可见。
  void _pushInCurrentBranch(Widget page) {
    navigationShell
        .route
        .branches[navigationShell.currentIndex]
        .navigatorKey
        .currentState
        ?.push(MaterialPageRoute<void>(builder: (_) => page));
  }

  /// 手机：底部导航 + 悬浮迷你播放条。
  Widget _buildCompact(BuildContext context, bool hasQueue) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasQueue) const MiniPlayer(),
          NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: _selectDestination,
            destinations: [
              for (final (icon, selectedIcon, label) in _destinations)
                NavigationDestination(
                  icon: Icon(icon),
                  selectedIcon: Icon(selectedIcon),
                  label: label,
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 平板 / 小窗口：导航栏轨 + 底部完整播放条。
  Widget _buildMedium(BuildContext context, bool hasQueue) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: _selectDestination,
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: _AppMark(),
            ),
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: IconButton(
                    tooltip: '设置',
                    onPressed: () => context.push('/settings'),
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ),
              ),
            ),
            destinations: [
              for (final (icon, selectedIcon, label) in _destinations)
                NavigationRailDestination(
                  icon: Icon(icon),
                  selectedIcon: Icon(selectedIcon),
                  label: Text(label),
                ),
            ],
          ),
          Expanded(child: navigationShell),
        ],
      ),
      bottomNavigationBar: hasQueue ? const NowPlayingBar() : null,
    );
  }

  /// 桌面 / 大屏：侧边栏（导航 + 歌单快捷入口）+ 底部完整播放条。
  Widget _buildExpanded(BuildContext context, bool hasQueue) {
    return Scaffold(
      body: Row(
        children: [
          SideNav(
            selectedIndex: navigationShell.currentIndex,
            destinations: _destinations,
            onSelect: _selectDestination,
            onOpenPage: _pushInCurrentBranch,
          ),
          Expanded(child: navigationShell),
        ],
      ),
      bottomNavigationBar: hasQueue ? const NowPlayingBar() : null,
    );
  }
}

/// 应用标识（导航栏轨顶部）。
class _AppMark extends StatelessWidget {
  const _AppMark();

  @override
  Widget build(BuildContext context) {
    return Container(
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
    );
  }
}

/// 队列是否存在的选择器（驱动 MiniPlayer 显隐）。
final playerHasQueueProvider = Provider<bool>(
  (ref) => ref.watch(playerNotifierProvider.select((s) => s.hasQueue)),
);
