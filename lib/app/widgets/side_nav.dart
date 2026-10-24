import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart' show sourceRegistryProvider;
import '../../core/model/remote_playlist.dart';
import '../../core/source/capabilities.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/nav_intent.dart';
import '../../features/auth/presentation/channel/account_manage_page.dart';
import '../../features/home/home_page.dart' show LibraryTab;
import '../../features/library/data/library_providers.dart';
import '../../features/library/data/remote_playlists_provider.dart';
import '../../features/library/playlist_detail_page.dart';
import '../../features/library/remote_playlist_page.dart';

/// 桌面侧边栏：栏目导航 + 「我的音乐」+ 全部歌单（本地与各渠道账号歌单）。
///
/// 桌面音乐软件的通行布局：歌单常驻左侧一键直达，
/// 不必每次「资料库 → 歌单 → 滚动查找」。
class SideNav extends ConsumerWidget {
  const SideNav({
    super.key,
    required this.selectedIndex,
    required this.destinations,
    required this.onSelect,
    required this.onOpenPage,
  });

  static const double width = 232;

  final int selectedIndex;
  final List<(IconData, IconData, String)> destinations;
  final ValueChanged<int> onSelect;

  /// 在当前栏目里打开一个页面（保持侧边栏与播放条可见）。
  final ValueChanged<Widget> onOpenPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final localNames = ref.watch(playlistsProvider).valueOrNull ?? const [];

    final remote = <(RemotePlaylist, String)>[];
    var hasPersonalSource = false;
    var anyLoggedIn = false;
    for (final source in ref.watch(sourceRegistryProvider).all) {
      if (source is! RemotePlaylistCapable) continue;
      if (!(source as RemotePlaylistCapable).remotePlaylistsArePersonal) {
        continue;
      }
      hasPersonalSource = true;
      if (ref.watch(remotePlaylistCapableProvider(source.sourceId)) == null) {
        continue;
      }
      anyLoggedIn = true;
      final playlists =
          ref.watch(remotePlaylistsProvider(source.sourceId)).valueOrNull ??
          const <RemotePlaylist>[];
      for (final p in playlists) {
        remote.add((p, source.displayName));
      }
    }

    return Container(
      width: width,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: scheme.outlineVariant, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: const BoxDecoration(
                    gradient: AppTokens.brandGradient,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.graphic_eq_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Musaic',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
          for (var i = 0; i < destinations.length; i++)
            _NavItem(
              icon:
                  i == selectedIndex ? destinations[i].$2 : destinations[i].$1,
              label: destinations[i].$3,
              selected: i == selectedIndex,
              onTap: () => onSelect(i),
            ),
          const _Header('我的音乐'),
          _NavItem(
            icon: Icons.favorite_rounded,
            iconColor: AppTokens.accent,
            label: '我喜欢的音乐',
            onTap:
                () => context.go(
                  '/library',
                  extra: NavIntent<int>(LibraryTab.favorites.index),
                ),
          ),
          _NavItem(
            icon: Icons.history_rounded,
            label: '最近播放',
            onTap:
                () => context.go(
                  '/library',
                  extra: NavIntent<int>(LibraryTab.history.index),
                ),
          ),
          const _Header('歌单'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 8),
              children: [
                for (final name in localNames)
                  _NavItem(
                    icon: Icons.queue_music_rounded,
                    label: name,
                    dense: true,
                    onTap: () => onOpenPage(PlaylistDetailPage(name: name)),
                  ),
                for (final (playlist, sourceName) in remote)
                  _NavItem(
                    icon: Icons.cloud_queue_rounded,
                    label: playlist.name,
                    tooltip: '$sourceName · ${playlist.trackCount} 首',
                    dense: true,
                    onTap:
                        () =>
                            onOpenPage(RemotePlaylistPage(playlist: playlist)),
                  ),
                if (hasPersonalSource && !anyLoggedIn)
                  _NavItem(
                    icon: Icons.cloud_sync_rounded,
                    iconColor: AppTokens.accent,
                    label: '登录以同步账号歌单',
                    dense: true,
                    onTap: () => AccountManagePage.open(context),
                  ),
                if (localNames.isEmpty && remote.isEmpty && anyLoggedIn)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 16, 4),
                    child: Text(
                      '还没有歌单',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(),
          _NavItem(
            icon: Icons.settings_outlined,
            label: '设置',
            onTap: () => context.push('/settings'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.dense = false,
    this.iconColor,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool dense;
  final Color? iconColor;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg =
        selected ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.72);
    final item = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: selected ? scheme.surfaceContainerHighest : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: dense ? 7 : 10,
            ),
            child: Row(
              children: [
                Icon(icon, size: dense ? 18 : 20, color: iconColor ?? fg),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: dense ? 13 : 14,
                      color: fg,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? item : Tooltip(message: tooltip!, child: item);
  }
}
