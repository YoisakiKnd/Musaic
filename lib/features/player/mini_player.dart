import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../library/widgets/add_to_playlist_sheet.dart';
import '../shared/widgets/track_cover.dart';
import 'player_notifier.dart';
import 'widgets/player_controls.dart';

/// 迷你播放条（手机）：悬浮圆角卡片，贴于底部导航上方，
/// 底部 2px 进度线；点按或上滑打开播放页。
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

    // 播放失败标记（U4）：后台自动切歌失败时，此前迷你条毫无变化，
    // 用户会以为「就是没声音」。这里给出可见标记（进度线转错误色 + 图标），
    // 点按进播放页即可看到可重试的错误横幅。
    final hasError = ref.watch(
      playerNotifierProvider.select((s) => s.error != null),
    );
    final notifier = ref.read(playerNotifierProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: GestureDetector(
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
        child: Material(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 58,
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    TrackCover(coverUrl: track.coverUrl, size: 42, radius: 6),
                    const SizedBox(width: 10),
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
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              if (hasError) ...[
                                Icon(
                                  Icons.error_outline_rounded,
                                  size: 13,
                                  color: scheme.error,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Flexible(
                                child: Text(
                                  hasError ? '播放失败，点击查看' : track.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color:
                                        hasError
                                            ? scheme.error
                                            : scheme.onSurface.withValues(
                                              alpha: 0.6,
                                            ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // 正在听的歌直接加入歌单（日常可用性计划 D2）
                    IconButton(
                      tooltip: '加入歌单',
                      onPressed:
                          () => AddToPlaylistSheet.show(context, [track]),
                      icon: const Icon(Icons.playlist_add_rounded),
                    ),
                    const PlayPauseButton(size: 44, filled: false),
                    IconButton(
                      tooltip: '下一首',
                      onPressed: notifier.next,
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
              _MiniProgress(hasError: hasError),
            ],
          ),
        ),
      ),
    );
  }
}

/// 迷你条底部 2px 进度线。
///
/// 单独成一个 widget：进度每 100ms 变化一次，只该重画这一条线，
/// 而不是连同封面、标题、按钮整条迷你条一起重建。
class _MiniProgress extends ConsumerWidget {
  const _MiniProgress({required this.hasError});

  final bool hasError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(
      playerNotifierProvider.select((s) {
        final total = s.duration?.inMilliseconds ?? 0;
        if (total <= 0) return 0.0;
        // 量化到 0.1%：避免进度没有肉眼可见变化时也触发重建
        return ((s.position.inMilliseconds / total).clamp(0.0, 1.0) * 1000)
                .round() /
            1000;
      }),
    );
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: LinearProgressIndicator(
        value: progress,
        minHeight: 2,
        backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
        valueColor: AlwaysStoppedAnimation<Color>(
          hasError ? scheme.error : scheme.onSurface.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}
