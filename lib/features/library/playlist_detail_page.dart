import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_tokens.dart';
import '../player/player_notifier.dart';
import '../shared/widgets/track_tile.dart';

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

    final controller = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('重命名歌单'),
            content: TextField(
              controller: controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted:
                  (value) => Navigator.of(dialogContext).pop(value.trim()),
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
                    () =>
                        Navigator.of(dialogContext).pop(controller.text.trim()),
                child: const Text('保存'),
              ),
            ],
          ),
    );
    controller.dispose();
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(libraryRepositoryProvider);
    final tracks = repository.playlistTracks(name);

    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          IconButton(
            tooltip: '重命名',
            onPressed: () => _rename(context, ref, name),
            icon: const Icon(Icons.drive_file_rename_outline_rounded),
          ),
        ],
      ),
      floatingActionButton:
          tracks.isEmpty
              ? null
              : FloatingActionButton.extended(
                backgroundColor: AppTokens.accent,
                foregroundColor: Colors.white,
                onPressed: () {
                  ref.read(playerNotifierProvider.notifier).playQueue(tracks);
                  context.push('/player');
                },
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('播放全部'),
              ),
      body:
          tracks.isEmpty
              ? Center(
                child: Text(
                  '歌单还是空的，去搜索页添加歌曲吧',
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              )
              : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: tracks.length,
                itemBuilder:
                    (context, index) => TrackTile(
                      track: tracks[index],
                      queue: tracks,
                      onRemove:
                          () => repository.removeFromPlaylist(name, index),
                    ),
              ),
    );
  }
}
