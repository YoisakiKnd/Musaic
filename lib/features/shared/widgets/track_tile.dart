import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/model/track.dart';
import '../../../core/theme/app_tokens.dart';
import '../../library/data/library_providers.dart';
import '../../library/widgets/add_to_playlist_sheet.dart';
import '../../player/player_notifier.dart';
import 'track_cover.dart';

/// 统一曲目行：封面 + 标题/歌手 + 渠道徽章 + 收藏心。
/// 点击即以 [queue] 为队列从本曲播放。
class TrackTile extends ConsumerWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.queue,
    this.onRemove,
    this.onLongPress,
    this.onTapOverride,
    this.onCheckboxChanged,
    this.dense = false,
    this.leadingCheckbox,
  });

  final Track track;
  final List<Track> queue;
  final VoidCallback? onRemove;

  /// 长按回调（如搜索页的「添加到歌单」）；缺省回落到 onRemove。
  final VoidCallback? onLongPress;

  /// 点击覆盖（多选模式下用于切换选中）；缺省为播放行为。
  final VoidCallback? onTapOverride;

  /// 多选框的独立回调（计划 4.3）。
  ///
  /// 此前勾选框直接借用 [onTapOverride]，于是「传了 leadingCheckbox 但没传
  /// onTapOverride」会得到一个**看起来可点、实际没反应**的勾选框 ——
  /// 界面在骗用户。现在两者解耦：勾选框优先用自己的回调，回落到
  /// [onTapOverride]；两者都为空时显式禁用（置灰），让「不可用」可见。
  final VoidCallback? onCheckboxChanged;

  /// 多选模式下的勾选态：null 表示不在多选模式。
  ///
  /// 由列表页传入而非内部维护——选中集合属于列表级状态，
  /// 放在 tile 内部会随列表滚动回收而丢失。
  final bool? leadingCheckbox;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(sourceRegistryProvider);
    final source = registry.resolve(track.sourceId);
    final isFavorite = ref.watch(isFavoriteProvider(track.key));
    final current = ref.watch(playerNotifierProvider.select((s) => s.current));
    final isCurrent = current?.key == track.key;
    final scheme = Theme.of(context).colorScheme;

    // 曲目行可能位于带背景色的容器内：显式透明 tileColor，
    // 避免「ink splashes may be invisible」诊断在每次重建时刷屏
    return ListTile(
      dense: dense,
      tileColor: Colors.transparent,
      onTap:
          onTapOverride ??
          () {
            ref
                .read(playerNotifierProvider.notifier)
                .playQueue(
                  queue,
                  startIndex: queue
                      .indexWhere((t) => t.key == track.key)
                      .clamp(0, queue.isEmpty ? 0 : queue.length - 1),
                );
            context.push('/player');
          },
      onLongPress:
          onLongPress ?? (onRemove ?? () => _quickPlayNext(context, ref)),
      leading:
          leadingCheckbox != null
              ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 计划 4.3：勾选框优先用自己的回调，回落到 onTapOverride。
                  // 两者都为空时传 null 给 onChanged → Checkbox 进入禁用态
                  // （置灰），「点了没反应」变成看得见的「不可用」。
                  Checkbox(
                    value: leadingCheckbox,
                    onChanged:
                        (onCheckboxChanged ?? onTapOverride) == null
                            ? null
                            : (_) =>
                                (onCheckboxChanged ?? onTapOverride)!.call(),
                    visualDensity: VisualDensity.compact,
                  ),
                  TrackCover(coverUrl: track.coverUrl),
                ],
              )
              : TrackCover(coverUrl: track.coverUrl),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: isCurrent ? AppTokens.accent : null,
        ),
      ),
      subtitle: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: AppTokens.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppTokens.radiusChip / 2),
            ),
            child: Text(
              source?.displayName ?? track.sourceId,
              style: const TextStyle(
                fontSize: 10,
                color: AppTokens.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              track.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onRemove != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.remove_circle_outline_rounded,
                size: 20,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
              onPressed: onRemove,
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '更多',
            onPressed: () => _openActions(context, ref),
            icon: Icon(
              Icons.more_vert_rounded,
              size: 20,
              color: scheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: isFavorite ? '取消喜欢' : '喜欢',
            onPressed: () => _toggleFavorite(context, ref),
            icon: Icon(
              isFavorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              size: 20,
              color:
                  isFavorite
                      ? AppTokens.accent
                      : scheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }

  /// 收藏开关（计划 3.3：补上失败反馈）。
  ///
  /// 此前是 `onPressed: () => repo.toggleFavorite(track)` 的裸调用：
  /// 写入失败（存储异常等）时异常直接冒泡到 Flutter 错误处理，
  /// 界面上**没有任何反馈**，用户会以为「点了但没生效」而反复点击。
  /// 现在失败必须落到可见提示上。
  Future<void> _toggleFavorite(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final wasFavorite = ref
        .read(libraryRepositoryProvider)
        .isFavorite(track.key);
    try {
      final added = await ref
          .read(libraryRepositoryProvider)
          .toggleFavorite(track);
      if (!context.mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(added ? '已加入喜欢' : '已取消喜欢')));
    } catch (e) {
      AppLog.error('收藏写入失败：${track.key} | $e', tag: 'MusaicLibrary');
      if (!context.mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(wasFavorite ? '取消喜欢失败，请重试' : '收藏失败，请重试')),
        );
    }
  }

  /// 曲目操作菜单（日常可用性计划 D2）。
  ///
  /// 此前收藏 / 历史 / 歌单详情里的曲目**只能播放或收藏**，
  /// 想加入歌单必须回搜索页重新找。此菜单把常用操作收在一处，
  /// 所有使用 [TrackTile] 的页面自动获得完整能力。
  Future<void> _openActions(BuildContext context, WidgetRef ref) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder:
          (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    track.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add_rounded),
                  title: const Text('加入歌单'),
                  onTap: () => Navigator.of(sheetContext).pop('playlist'),
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_play_rounded),
                  title: const Text('下一首播放'),
                  onTap: () => Navigator.of(sheetContext).pop('next'),
                ),
                ListTile(
                  leading: const Icon(Icons.queue_music_rounded),
                  title: const Text('添加到队列末尾'),
                  onTap: () => Navigator.of(sheetContext).pop('queue'),
                ),
                if (onRemove != null)
                  ListTile(
                    leading: const Icon(Icons.remove_circle_outline_rounded),
                    title: const Text('从当前列表移除'),
                    onTap: () => Navigator.of(sheetContext).pop('remove'),
                  ),
              ],
            ),
          ),
    );
    if (!context.mounted || action == null) return;

    switch (action) {
      case 'playlist':
        await AddToPlaylistSheet.show(context, [track]);
      case 'next':
        await _quickPlayNext(context, ref);
      case 'queue':
        ref.read(playerNotifierProvider.notifier).addToQueue(track);
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已添加「${track.title}」到队列')));
      case 'remove':
        onRemove?.call();
    }
  }

  /// 无自定义长按行为的曲目：快捷「下一首播放」。
  Future<void> _quickPlayNext(BuildContext context, WidgetRef ref) async {
    unawaited(ref.read(playerNotifierProvider.notifier).insertNext(track));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('下一首播放「${track.title}」')));
  }
}
