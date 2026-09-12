import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart'
    show libraryRepositoryProvider, sourceRegistryProvider;
import '../../core/model/remote_playlist.dart';
import '../../core/model/track.dart';
import '../../core/source/capabilities.dart';
import '../../core/source/music_source.dart';
import '../../core/theme/app_tokens.dart';
import 'data/library_repository.dart';
import 'data/remote_playlists_provider.dart';
import 'remote_playlist_page.dart';
import '../player/player_notifier.dart';
import '../shared/widgets/track_tile.dart';
import 'data/library_providers.dart';

/// 资料库：喜欢 / 最近播放 / 自建歌单（Master Plan P6）。
class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('资料库'),
          bottom: const TabBar(
            tabs: [Tab(text: '喜欢'), Tab(text: '最近播放'), Tab(text: '歌单')],
          ),
        ),
        body: const TabBarView(
          children: [_FavoritesTab(), _HistoryTab(), _PlaylistsTab()],
        ),
      ),
    );
  }
}

class _FavoritesTab extends ConsumerWidget {
  const _FavoritesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favoritesAsync = ref.watch(favoritesProvider);
    return favoritesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败：$e')),
      data: (favorites) {
        if (favorites.isEmpty) {
          return const _EmptyHint(
            icon: Icons.favorite_border_rounded,
            text: '喜欢的歌曲会出现在这里',
          );
        }
        // 播放全部 + 批量管理（日常可用性计划 D3）：
        // 此前收藏只有单曲 tile，没有「播放全部」，也无法批量整理。
        return _TrackListWithActions(
          tracks: favorites,
          storageKey: 'favorites',
          onClear: () async {
            await ref.read(libraryRepositoryProvider).clearFavorites();
          },
          clearLabel: '清空喜欢的音乐',
        );
      },
    );
  }
}

class _HistoryTab extends ConsumerWidget {
  const _HistoryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(recentHistoryProvider);
    return historyAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败：$e')),
      data: (history) {
        if (history.isEmpty) {
          return const _EmptyHint(
            icon: Icons.history_rounded,
            text: '播放过的歌曲会出现在这里',
          );
        }
        // 最近播放同样支持播放全部与批量删除（D3）。
        // 历史无「清空」语义上的歧义，故不提供一键清空入口。
        return _TrackListWithActions(tracks: history, storageKey: 'history');
      },
    );
  }
}

class _PlaylistsTab extends ConsumerWidget {
  const _PlaylistsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(playlistsProvider);
    final repository = ref.watch(libraryRepositoryProvider);

    return Stack(
      children: [
        playlistsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('加载失败：$e')),
          data: (names) {
            // 所有实现 RemotePlaylistCapable 的渠道各渲染一个账号歌单区
            final remoteSources = <MusicSource>[
              for (final s in ref.watch(sourceRegistryProvider).all)
                if (s is RemotePlaylistCapable) s,
            ];
            final hasAnyRemote = remoteSources.isNotEmpty;
            if (names.isEmpty && !hasAnyRemote) {
              return const _EmptyHint(
                icon: Icons.queue_music_rounded,
                text: '创建你的第一个歌单',
              );
            }
            return ListView(
              padding: AppTokens.pagePadding,
              children: [
                for (final source in remoteSources)
                  _RemotePlaylistSection(
                    key: ValueKey('remote-playlists-${source.sourceId}'),
                    sourceId: source.sourceId,
                    displayName: source.displayName,
                  ),
                if (names.isNotEmpty) ...[
                  const _SectionTitle('本地歌单'),
                  for (final name in names) _LocalPlaylistCard(name: name),
                ],
              ],
            );
          },
        ),
        Positioned(
          right: 24,
          bottom: 24,
          child: FloatingActionButton.extended(
            backgroundColor: AppTokens.accent,
            foregroundColor: Colors.white,
            onPressed: () async {
              final controller = TextEditingController();
              final name = await showDialog<String>(
                context: context,
                builder:
                    (dialogContext) => AlertDialog(
                      title: const Text('新建歌单'),
                      content: TextField(
                        controller: controller,
                        autofocus: true,
                        decoration: const InputDecoration(hintText: '歌单名称'),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTokens.accent,
                          ),
                          onPressed:
                              () => Navigator.of(
                                dialogContext,
                              ).pop(controller.text.trim()),
                          child: const Text('创建'),
                        ),
                      ],
                    ),
              );
              controller.dispose();
              if (name != null && name.isNotEmpty) {
                await repository.createPlaylist(name);
              }
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('新建歌单'),
          ),
        ),
      ],
    );
  }
}

/// 带「播放全部」与批量管理的曲目列表（日常可用性计划 D3）。
///
/// 收藏与最近播放共用：两者都是「一维曲目列表」，此前只有单曲 tile，
/// 既不能一键播放全部，也无法批量删除。抽成一个组件避免两处重复实现。
class _TrackListWithActions extends ConsumerStatefulWidget {
  const _TrackListWithActions({
    required this.tracks,
    required this.storageKey,
    this.onClear,
    this.clearLabel,
  });

  final List<Track> tracks;

  /// 仅用于区分选中态（切换 tab 时重置）。
  final String storageKey;

  /// 一键清空回调；为 null 时不显示该入口。
  final Future<void> Function()? onClear;
  final String? clearLabel;

  @override
  ConsumerState<_TrackListWithActions> createState() =>
      _TrackListWithActionsState();
}

class _TrackListWithActionsState extends ConsumerState<_TrackListWithActions> {
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggle(String key) {
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  Future<void> _removeSelected() async {
    final repository = ref.read(libraryRepositoryProvider);
    final keys = Set<String>.of(_selected);
    if (keys.isEmpty) return;

    // 逐条删除是唯一可行路径（Hive 无按谓词批量删），
    // 但先收集再删，避免在遍历中修改集合。
    for (final track in widget.tracks) {
      if (keys.contains(track.key)) {
        await repository.toggleFavorite(track); // 收藏态取反 = 移除
      }
    }
    if (!mounted) return;
    _exitSelection();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已移除 ${keys.length} 首')));
  }

  Future<void> _confirmClear() async {
    final onClear = widget.onClear;
    if (onClear == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(widget.clearLabel ?? '确认清空'),
            content: const Text('该操作不可恢复。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTokens.accent,
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('清空'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    await onClear();
    if (!mounted) return;
    _exitSelection();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${widget.clearLabel ?? '已清空'}完成')));
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.tracks;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTokens.accent,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () {
                  ref.read(playerNotifierProvider.notifier).playQueue(tracks);
                  context.push('/player');
                },
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: Text('播放全部（${tracks.length}）'),
              ),
              const Spacer(),
              if (_selecting) ...[
                Text(
                  '已选 ${_selected.length}',
                  style: const TextStyle(fontSize: 12),
                ),
                IconButton(
                  tooltip: '移除所选',
                  onPressed: _selected.isEmpty ? null : _removeSelected,
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
                IconButton(
                  tooltip: '取消',
                  onPressed: _exitSelection,
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ] else ...[
                IconButton(
                  tooltip: '批量选择',
                  onPressed: () => setState(() => _selecting = true),
                  icon: const Icon(Icons.checklist_rounded, size: 20),
                ),
                if (widget.onClear != null)
                  IconButton(
                    tooltip: widget.clearLabel ?? '清空',
                    onPressed: _confirmClear,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                  ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: AppTokens.pagePadding,
            itemCount: tracks.length,
            itemBuilder: (context, index) {
              final track = tracks[index];
              final checked = _selected.contains(track.key);
              return TrackTile(
                track: track,
                queue: tracks,
                dense: true,
                onTapOverride: _selecting ? () => _toggle(track.key) : null,
                leadingCheckbox: _selecting ? checked : null,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 56, color: AppTokens.accent.withValues(alpha: 0.45)),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分区标题。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Text(
        text,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// 单个渠道的账号歌单分区。
///
/// 三态渲染（B6）：加载中出骨架行，失败出「错误 + 重试」，成功才渲染歌单；
/// 空列表（未登录 / 无歌单 / 渠道不支持）整节隐藏，不占版面。
class _RemotePlaylistSection extends ConsumerWidget {
  const _RemotePlaylistSection({
    super.key,
    required this.sourceId,
    required this.displayName,
  });

  final String sourceId;
  final String displayName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 未登录 / 渠道不支持：连标题都不出现，避免留下永远不会填上的空节
    if (ref.watch(remotePlaylistCapableProvider(sourceId)) == null) {
      return const SizedBox.shrink();
    }

    final playlistsAsync = ref.watch(remotePlaylistsProvider(sourceId));
    return playlistsAsync.when(
      loading: () => const _RemotePlaylistLoading(),
      error:
          (error, _) => _RemotePlaylistError(
            displayName: displayName,
            message: remotePlaylistsErrorMessage(error),
            onRetry: () => ref.invalidate(remotePlaylistsProvider(sourceId)),
          ),
      data: (playlists) {
        if (playlists.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionTitle('账号歌单 · $displayName'),
            for (final pl in playlists) _RemotePlaylistCard(playlist: pl),
            const SizedBox(height: 12),
          ],
        );
      },
    );
  }
}

/// 账号歌单加载态。
///
/// 用一行文字 + 小圈而不是整块骨架屏：账号歌单只是资料库里的一个分区，
/// 大骨架会把本地歌单挤下去，数据到达时整页跳动。
class _RemotePlaylistLoading extends StatelessWidget {
  const _RemotePlaylistLoading();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            '正在加载账号歌单…',
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// 账号歌单加载失败行：错误原因 + 重试入口（B6）。
class _RemotePlaylistError extends StatelessWidget {
  const _RemotePlaylistError({
    required this.displayName,
    required this.message,
    required this.onRetry,
  });

  final String displayName;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 16,
            color: scheme.error.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '账号歌单 · $displayName：$message',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重试'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: AppTokens.accent,
            ),
          ),
        ],
      ),
    );
  }
}

/// 渠道账号歌单卡片。
class _RemotePlaylistCard extends ConsumerWidget {
  const _RemotePlaylistCard({required this.playlist});

  final RemotePlaylist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusCard - 4),
        ),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppTokens.accentDeep.withValues(alpha: 0.3),
                AppTokens.accent.withValues(alpha: 0.3),
              ],
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.cloud_queue_rounded, color: Colors.white70),
        ),
        title: Text(
          playlist.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          playlist.playCount == null
              ? '${playlist.trackCount} 首'
              : '${playlist.trackCount} 首 · ${playlist.playCount} 次播放',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: scheme.onSurface.withValues(alpha: 0.4),
        ),
        onTap:
            () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RemotePlaylistPage(playlist: playlist),
              ),
            ),
      ),
    );
  }
}

/// 本地歌单卡片。
class _LocalPlaylistCard extends ConsumerWidget {
  const _LocalPlaylistCard({required this.name});

  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(libraryRepositoryProvider);
    final count = repository.playlistTracks(name).length;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusCard - 4),
        ),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppTokens.accentDeep.withValues(alpha: 0.3),
                AppTokens.accent.withValues(alpha: 0.3),
              ],
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.queue_music_rounded, color: Colors.white70),
        ),
        title: Text(name),
        subtitle: Text('$count 首', style: const TextStyle(fontSize: 12)),
        trailing: IconButton(
          icon: Icon(
            Icons.delete_outline_rounded,
            size: 20,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.5),
          ),
          onPressed: () => _confirmDelete(context, repository),
        ),
        onTap: () => context.push('/playlist/${Uri.encodeComponent(name)}'),
      ),
    );
  }

  /// 删除歌单是不可恢复操作：先二次确认再落库（P2）。
  ///
  /// 文案必须带上歌单名——列表里每张卡片都有删除按钮，
  /// 只写「确认删除？」在误触时无法判断删的是哪一个。
  Future<void> _confirmDelete(
    BuildContext context,
    LibraryRepository repository,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('删除歌单'),
            content: Text('确定删除歌单「$name」吗？该操作不可恢复。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(dialogContext).colorScheme.error,
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    await repository.deletePlaylist(name);
  }
}
