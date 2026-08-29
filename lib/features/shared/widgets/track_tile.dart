import 'dart:async' show unawaited;
import 'dart:io' show File;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/model/track.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/cover_network.dart';
import '../../library/data/library_providers.dart';
import '../../player/player_notifier.dart';

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
    this.dense = false,
  });

  final Track track;
  final List<Track> queue;
  final VoidCallback? onRemove;

  /// 长按回调（如搜索页的「添加到歌单」）；缺省回落到 onRemove。
  final VoidCallback? onLongPress;

  /// 点击覆盖（多选模式下用于切换选中）；缺省为播放行为。
  final VoidCallback? onTapOverride;
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
      leading: _TileCover(coverUrl: track.coverUrl),
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
            onPressed:
                () => ref.read(libraryRepositoryProvider).toggleFavorite(track),
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

  /// 无自定义长按行为的曲目：快捷「下一首播放」。
  Future<void> _quickPlayNext(BuildContext context, WidgetRef ref) async {
    unawaited(ref.read(playerNotifierProvider.notifier).insertNext(track));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('下一首播放「${track.title}」')));
  }
}

class _TileCover extends StatelessWidget {
  const _TileCover({required this.coverUrl});

  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    const Widget fallback = SizedBox(
      width: 48,
      height: 48,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppTokens.brandGradient,
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        child: Icon(Icons.music_note_rounded, size: 20, color: Colors.white70),
      ),
    );
    final url = coverUrl;
    if (url == null || url.isEmpty) return fallback;
    if (url.startsWith('file://')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          File(Uri.parse(url).toFilePath()),
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          cacheWidth: 96, // 解码尺寸上限（迭代计划 §9.1）
          errorBuilder: (_, _, _) => fallback,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: CachedNetworkImage(
        imageUrl: normalizeCoverUrl(url),
        httpHeaders: coverHttpHeaders(url),
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        memCacheWidth: 96,
        fadeInDuration: AppTokens.durationFast,
        placeholder:
            (_, _) => ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const SizedBox(width: 48, height: 48),
            ),
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}
