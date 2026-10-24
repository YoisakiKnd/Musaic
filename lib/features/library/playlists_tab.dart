import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart'
    show libraryRepositoryProvider, sourceRegistryProvider;
import '../../core/logging/app_logger.dart';
import '../../core/model/remote_playlist.dart';
import '../../core/source/capabilities.dart';
import '../../core/source/music_source.dart';
import '../../core/theme/app_tokens.dart';
import '../auth/presentation/channel/account_manage_page.dart';
import '../player/player_notifier.dart';
import '../shared/error_text.dart';
import '../shared/widgets/text_input_dialog.dart';
import 'data/library_providers.dart';
import 'data/library_repository.dart';
import 'data/remote_playlists_provider.dart';
import 'remote_playlist_page.dart';
import 'widgets/playlist_card.dart';

/// 资料库「歌单」页：账号歌单（按渠道分节）+ 本地歌单，封面网格展示。
///
/// 此前账号歌单藏在第三个 Tab 的列表最上方、未登录时整节隐藏，
/// 用户登录后找不到、没登录也不知道这里会有账号歌单（真机反馈）。
/// 现在：「歌单」是资料库首个 Tab；没有登录任何可同步歌单的渠道时
/// 顶部给出「去登录」引导。
class PlaylistsTab extends ConsumerWidget {
  const PlaylistsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(playlistsProvider);
    final remoteSources = <MusicSource>[
      for (final s in ref.watch(sourceRegistryProvider).all)
        if (s is RemotePlaylistCapable) s,
    ];
    final anyPersonalLoggedIn = remoteSources.any((s) {
      final capable = ref.watch(remotePlaylistCapableProvider(s.sourceId));
      return capable != null && capable.remotePlaylistsArePersonal;
    });
    final hasPersonalSource = remoteSources.any(
      (s) => (s as RemotePlaylistCapable).remotePlaylistsArePersonal,
    );

    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              sliver: SliverMainAxisGroup(
                slivers: [
                  if (hasPersonalSource && !anyPersonalLoggedIn)
                    const SliverToBoxAdapter(
                      child: AccountPlaylistsLoginHint(),
                    ),
                  for (final source in remoteSources)
                    _RemotePlaylistSection(
                      key: ValueKey('remote-playlists-${source.sourceId}'),
                      sourceId: source.sourceId,
                      displayName: source.displayName,
                    ),
                  ...playlistsAsync.when(
                    loading:
                        () => const [
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.all(32),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          ),
                        ],
                    error:
                        (e, _) => [
                          SliverToBoxAdapter(
                            child: Center(
                              child: Text(
                                loadFailureText(e, tag: 'MusaicLibrary'),
                              ),
                            ),
                          ),
                        ],
                    data:
                        (names) => [
                          const SliverToBoxAdapter(
                            child: _SectionHeader(title: '本地歌单'),
                          ),
                          if (names.isEmpty)
                            const SliverToBoxAdapter(
                              child: _NoLocalPlaylistsHint(),
                            )
                          else
                            PlaylistGrid(
                              itemCount: names.length,
                              itemBuilder:
                                  (context, index) =>
                                      LocalPlaylistCard(name: names[index]),
                            ),
                        ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const Positioned(right: 24, bottom: 24, child: _CreatePlaylistButton()),
      ],
    );
  }
}

/// 自适应列数的歌单网格（手机 2–3 列，桌面更多）。
///
/// 卡片高度 = 方形封面 + 两行文字；用固定 `mainAxisExtent` 而不是宽高比，
/// 宽高比在不同列宽下会让文字区忽高忽低甚至溢出。
class PlaylistGrid extends StatelessWidget {
  const PlaylistGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  static const double _spacing = 8;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final columns = (width / 170).floor().clamp(2, 8);
        final itemWidth = (width - _spacing * (columns - 1)) / columns;
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: _spacing,
            mainAxisSpacing: _spacing,
            // 封面边长 = itemWidth - 8（卡片内边距），文字两行约 50
            mainAxisExtent: itemWidth + 50 * textScale,
          ),
          delegate: SliverChildBuilderDelegate(
            itemBuilder,
            childCount: itemCount,
          ),
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Text(
              trailing!,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 未登录任何可同步歌单的渠道时的引导卡（资料库 / 首页共用）。
class AccountPlaylistsLoginHint extends StatelessWidget {
  const AccountPlaylistsLoginHint({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            const Icon(Icons.cloud_sync_rounded, color: AppTokens.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '同步你的账号歌单',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '登录网易云音乐或 QQ 音乐后，歌单会出现在这里',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => AccountManagePage.open(context),
              child: const Text('去登录'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个渠道的远端歌单分区。
///
/// 三态渲染（B6）：加载中出一行进度，失败出「错误 + 重试」，成功才渲染网格；
/// 未登录 / 渠道不支持 / 空列表时整节隐藏，不占版面。
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
    final capable = ref.watch(remotePlaylistCapableProvider(sourceId));
    if (capable == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final kind = capable.remotePlaylistsArePersonal ? '我的歌单' : '推荐歌单';

    final playlistsAsync = ref.watch(remotePlaylistsProvider(sourceId));
    return playlistsAsync.when(
      loading:
          () => SliverToBoxAdapter(
            child: _RemotePlaylistLoading(label: '$displayName · $kind'),
          ),
      error:
          (error, _) => SliverToBoxAdapter(
            child: _RemotePlaylistError(
              displayName: displayName,
              message: remotePlaylistsErrorMessage(error),
              onRetry: () => ref.invalidate(remotePlaylistsProvider(sourceId)),
            ),
          ),
      data: (playlists) {
        if (playlists.isEmpty) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: _SectionHeader(
                title: displayName,
                trailing: '$kind · ${playlists.length}',
              ),
            ),
            PlaylistGrid(
              itemCount: playlists.length,
              itemBuilder:
                  (context, index) =>
                      RemotePlaylistCard(playlist: playlists[index]),
            ),
          ],
        );
      },
    );
  }
}

/// 远端歌单卡片（资料库网格 / 首页横滑共用）。
class RemotePlaylistCard extends StatelessWidget {
  const RemotePlaylistCard({super.key, required this.playlist, this.badge});

  final RemotePlaylist playlist;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return PlaylistCard(
      title: playlist.name,
      subtitle: playlistSubtitle(
        playlist.trackCount,
        playCount: playlist.playCount,
      ),
      coverUrl: playlist.coverUrl,
      badge: badge,
      // 推当前分支的 Navigator：底部导航与迷你播放条保持可见
      onTap:
          () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RemotePlaylistPage(playlist: playlist),
            ),
          ),
    );
  }
}

class _RemotePlaylistLoading extends StatelessWidget {
  const _RemotePlaylistLoading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            '正在加载 $label…',
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

/// 歌单加载失败行：错误原因 + 重试入口（B6）。
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
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
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
              '$displayName 歌单：$message',
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

/// 还没有本地歌单时的引导（不居中占满：上方可能还有账号歌单分区）。
class _NoLocalPlaylistsHint extends StatelessWidget {
  const _NoLocalPlaylistsHint();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      child: Column(
        children: [
          Icon(
            Icons.queue_music_rounded,
            size: 44,
            color: AppTokens.accent.withValues(alpha: 0.8),
          ),
          const SizedBox(height: 12),
          const Text(
            '还没有歌单',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            '点右下角「新建歌单」，或在任意歌曲的「⋮」菜单里选择「加入歌单」',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: scheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}

/// 本地歌单卡片：封面取歌单第一首歌；长按弹出操作菜单。
class LocalPlaylistCard extends ConsumerWidget {
  const LocalPlaylistCard({super.key, required this.name, this.onOpen});

  final String name;

  /// 打开详情的方式；缺省走资料库分支的 `/playlist/:name` 路由。
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 跟随资料库变化重建（加歌 / 删歌后封面与曲目数要刷新）
    ref.watch(playlistsProvider);
    final repository = ref.watch(libraryRepositoryProvider);
    final tracks = repository.playlistTracks(name);
    final cover = tracks
        .map((t) => t.coverUrl)
        .firstWhere((u) => u != null && u.isNotEmpty, orElse: () => null);
    return PlaylistCard(
      title: name,
      subtitle: playlistSubtitle(tracks.length),
      coverUrl: cover,
      badge: '本地',
      onTap:
          onOpen ??
          () => context.push('/playlist/${Uri.encodeComponent(name)}'),
      onLongPress: () => _showActions(context, ref, repository),
    );
  }

  Future<void> _showActions(
    BuildContext context,
    WidgetRef ref,
    LibraryRepository repository,
  ) async {
    final tracks = repository.playlistTracks(name);
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder:
          (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.play_arrow_rounded),
                  title: const Text('播放'),
                  enabled: tracks.isNotEmpty,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    ref.read(playerNotifierProvider.notifier).playQueue(tracks);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.shuffle_rounded),
                  title: const Text('随机播放'),
                  enabled: tracks.isNotEmpty,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    ref
                        .read(playerNotifierProvider.notifier)
                        .shufflePlay(tracks);
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.delete_outline_rounded,
                    color: Theme.of(sheetContext).colorScheme.error,
                  ),
                  title: Text(
                    '删除歌单',
                    style: TextStyle(
                      color: Theme.of(sheetContext).colorScheme.error,
                    ),
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _confirmDelete(context, repository);
                  },
                ),
              ],
            ),
          ),
    );
  }

  /// 删除歌单不可恢复：先二次确认（文案带歌单名，误触时能看出删的是哪个）。
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

class _CreatePlaylistButton extends ConsumerWidget {
  const _CreatePlaylistButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(libraryRepositoryProvider);
    return FloatingActionButton.extended(
      backgroundColor: AppTokens.accent,
      foregroundColor: Colors.white,
      onPressed: () async {
        final name = await showTextInputDialog(
          context,
          title: '新建歌单',
          confirmLabel: '创建',
        );
        if (name == null || name.trim().isEmpty || !context.mounted) {
          return;
        }
        final messenger = ScaffoldMessenger.of(context);
        // 重名时 createPlaylist 静默不建，此前用户点了「创建」毫无反馈
        if (repository.playlistNames.contains(name.trim())) {
          messenger.showSnackBar(
            SnackBar(content: Text('已有名为「${name.trim()}」的歌单')),
          );
          return;
        }
        try {
          await repository.createPlaylist(name);
          messenger.showSnackBar(
            SnackBar(content: Text('已创建「${name.trim()}」')),
          );
        } on ArgumentError catch (e) {
          // 名称过长等校验失败：给出原因，而不是让异常冒到全局
          messenger.showSnackBar(SnackBar(content: Text('${e.message}')));
        } catch (e) {
          AppLog.error('新建歌单失败：$e', tag: 'MusaicLibrary');
          messenger.showSnackBar(const SnackBar(content: Text('创建失败，请重试')));
        }
      },
      icon: const Icon(Icons.add_rounded),
      label: const Text('新建歌单'),
    );
  }
}
