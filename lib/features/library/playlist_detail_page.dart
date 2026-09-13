import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/model/track.dart';
import '../../core/theme/app_tokens.dart';
import '../player/player_notifier.dart';
import '../shared/widgets/text_input_dialog.dart';
import '../shared/widgets/track_tile.dart';
import 'data/library_providers.dart';
import 'data/library_repository.dart';

/// 歌单详情（Master Plan P6）：播放全部 / 移除单曲 / 重命名。
class PlaylistDetailPage extends ConsumerWidget {
  const PlaylistDetailPage({super.key, required this.name});

  final String name;

  /// 重命名歌单（日常可用性计划 D4）。
  ///
  /// 改名后必须把当前路由替换为新名字：歌单以名字为键取数据，
  /// 停留在旧名会显示成空歌单，用户会以为内容丢了。
  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    String currentName,
  ) async {
    // 在**任何 await 之前**取出依赖 BuildContext 的对象。
    // 本组件是无状态 ConsumerWidget，没有 mounted 可判断，
    // 跨 async gap 使用 context 会触发 use_build_context_synchronously。
    final repository = ref.read(libraryRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    final newName = await showTextInputDialog(
      context,
      title: '重命名歌单',
      confirmLabel: '保存',
      initialValue: currentName,
    );
    if (newName == null || newName.isEmpty || newName == currentName) return;

    final ok = await repository.renamePlaylist(currentName, newName);
    if (!ok) {
      // 撞名或原歌单不存在：明确告知，不静默失败
      messenger.showSnackBar(
        SnackBar(content: Text('重命名失败：「$newName」已存在或原歌单不存在')),
      );
      return;
    }
    // pushReplacement 的 Future 在路由替换完成后才 resolve，此处无需等待
    unawaited(
      router.pushReplacement('/playlist/${Uri.encodeComponent(newName)}'),
    );
    messenger.showSnackBar(SnackBar(content: Text('已重命名为「$newName」')));
  }

  /// 歌单排序（基准项「播放列表 · 排序」）。
  ///
  /// 排序会写回存储，因此成功后给出反馈并刷新列表；
  /// 失败（歌单不存在 / 少于 2 首）不静默。
  Future<void> _sort(BuildContext context, WidgetRef ref, String name) async {
    final repository = ref.read(libraryRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final order = await showModalBottomSheet<PlaylistSortOrder>(
      context: context,
      builder:
          (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '排序方式',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                for (final option in PlaylistSortOrder.values)
                  if (option != PlaylistSortOrder.manual)
                    ListTile(
                      title: Text(option.label),
                      onTap: () => Navigator.of(sheetContext).pop(option),
                    ),
              ],
            ),
          ),
    );
    if (order == null) return;

    final ok = await repository.sortPlaylist(name, order);
    messenger.showSnackBar(
      SnackBar(content: Text(ok ? '已${order.label}排序' : '排序失败：歌单不存在或曲目不足 2 首')),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(libraryRepositoryProvider);
    // 响应式读取曲目（U2）：别处对歌单的写入会推送到这里，
    // 不再依赖「退出重进」才能看到新内容。
    final tracksAsync = ref.watch(playlistTracksProvider(name));

    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          // 少于 2 首没有可排序的意义，禁用而不是点了没反应
          IconButton(
            tooltip: '排序',
            onPressed:
                (tracksAsync.valueOrNull?.length ?? 0) < 2
                    ? null
                    : () => _sort(context, ref, name),
            icon: const Icon(Icons.sort_rounded),
          ),
          IconButton(
            tooltip: '重命名',
            onPressed: () => _rename(context, ref, name),
            icon: const Icon(Icons.drive_file_rename_outline_rounded),
          ),
        ],
      ),
      body: tracksAsync.when(
        // 加载态：首次订阅是同步 yield，理论上不出现；
        // 但保留明确分支，避免将来改成异步源时静默显示空态。
        loading: () => const Center(child: CircularProgressIndicator()),
        error:
            (error, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline_rounded, size: 40),
                    const SizedBox(height: 12),
                    const Text('歌单内容读取失败'),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed:
                          () => ref.invalidate(playlistTracksProvider(name)),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
        data: (tracks) => _buildContent(context, ref, repository, tracks),
      ),
      floatingActionButton: tracksAsync.maybeWhen(
        data:
            (tracks) =>
                tracks.isEmpty
                    ? null
                    : FloatingActionButton.extended(
                      backgroundColor: AppTokens.accent,
                      foregroundColor: Colors.white,
                      onPressed: () {
                        ref
                            .read(playerNotifierProvider.notifier)
                            .playQueue(tracks);
                        context.push('/player');
                      },
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('播放全部'),
                    ),
        orElse: () => null,
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    LibraryRepository repository,
    List<Track> tracks,
  ) {
    if (tracks.isEmpty) {
      return Center(
        child: Text(
          '歌单还是空的，去搜索页添加歌曲吧',
          style: TextStyle(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        // 计划 4.2：在渲染时就把要删的曲目定下来，按 key 删除。
        // 原先传的是下标，若列表在渲染与点击之间发生重排
        // （响应式刷新、别处写入），下标会指向另一首歌 ——
        // 用户点 A 却删掉 B。key 与顺序无关。
        final track = tracks[index];
        return TrackTile(
          track: track,
          queue: tracks,
          onRemove: () => repository.removeFromPlaylistByKey(name, track.key),
        );
      },
    );
  }
}
