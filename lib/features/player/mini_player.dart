import 'dart:io' show File;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_tokens.dart';
import '../../core/utils/cover_network.dart';
import 'player_notifier.dart';

/// 迷你播放条（传统 Material 风格）：全宽方角、贴于底部导航上方，
/// 顶部 2px 进度线；点按或上滑打开播放页。
class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key});

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  double _dragDy = 0;

  void _openPlayer(BuildContext context) => context.push('/player');

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(playerNotifierProvider.select((s) => s.current));
    if (track == null) return const SizedBox.shrink();

    final playing = ref.watch(playerNotifierProvider.select((s) => s.playing));
    final position = ref.watch(
      playerNotifierProvider.select((s) => s.position),
    );
    final duration = ref.watch(
      playerNotifierProvider.select((s) => s.duration),
    );
    final notifier = ref.read(playerNotifierProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    final progress =
        (duration != null && duration.inMilliseconds > 0)
            ? (position.inMilliseconds / duration.inMilliseconds).clamp(
              0.0,
              1.0,
            )
            : 0.0;

    return GestureDetector(
      onTap: () => _openPlayer(context),
      // 上滑手势：一甩或拖动超过 60px 即进入播放页
      onVerticalDragUpdate: (details) {
        if (details.delta.dy < 0) _dragDy += -details.delta.dy;
      },
      onVerticalDragEnd: (details) {
        final flick = details.velocity.pixelsPerSecond.dy < -350;
        final dragged = _dragDy > 60;
        _dragDy = 0;
        if (flick || dragged) _openPlayer(context);
      },
      child: Container(
        color: scheme.surfaceContainerHighest,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
              valueColor: const AlwaysStoppedAnimation<Color>(AppTokens.accent),
            ),
            // 固定高度 + Row 精确居中（ListTile 的 leading/trailing 基线
            // 在 64dp 行高里难以对齐，这里全部手工约束）
            SizedBox(
              height: 64,
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  _Cover(coverUrl: track.coverUrl),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${track.artist}${track.album == null ? '' : ' · ${track.album}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: playing ? '暂停' : '播放',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: notifier.toggle,
                    icon: Icon(
                      playing
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                      size: 34,
                    ),
                  ),
                  IconButton(
                    tooltip: '下一首',
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 48,
                    ),
                    onPressed: notifier.next,
                    icon: const Icon(Icons.skip_next_rounded),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 迷你条封面：网络图 / 本地文件图 / 品牌渐变占位。
class _Cover extends StatelessWidget {
  const _Cover({required this.coverUrl});

  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    final Widget placeholder = Container(
      width: 44,
      height: 44,
      decoration: const BoxDecoration(gradient: AppTokens.brandGradient),
      child: const Icon(Icons.music_note_rounded, color: Colors.white70),
    );
    final url = coverUrl;
    if (url == null || url.isEmpty) return placeholder;
    if (url.startsWith('file://')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(Uri.parse(url).toFilePath()),
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          cacheWidth: 88, // 解码尺寸上限（迭代计划 §9.1）
          errorBuilder: (_, _, _) => placeholder,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: normalizeCoverUrl(url),
        httpHeaders: coverHttpHeaders(url),
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        memCacheWidth: 88,
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      ),
    );
  }
}
