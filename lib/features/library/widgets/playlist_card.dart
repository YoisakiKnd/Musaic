import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';
import '../../shared/widgets/track_cover.dart';

/// 歌单封面卡：方形封面 + 名称 + 副标题（首页横滑 / 资料库网格共用）。
///
/// 此前歌单只有一行「渐变色块 + 图标」的 ListTile，渠道明明返回了封面
/// 却没用上，一屏全是一模一样的色块，认不出哪个是哪个。
class PlaylistCard extends StatelessWidget {
  const PlaylistCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.coverUrl,
    this.badge,
    this.onLongPress,
  });

  final String title;
  final String subtitle;
  final String? coverUrl;

  /// 封面左下角的小标签（如渠道名），首页混排多个渠道时用来区分来源。
  final String? badge;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(AppTokens.radiusCard),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder:
                  (context, constraints) => Stack(
                    children: [
                      TrackCover(
                        coverUrl: coverUrl,
                        size: constraints.maxWidth,
                        radius: 14,
                      ),
                      if (badge != null)
                        Positioned(
                          left: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              badge!,
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 与 [PlaylistCard] 同尺寸的操作卡（「登录同步歌单」「新建歌单」）。
class PlaylistActionCard extends StatelessWidget {
  const PlaylistActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.radiusCard),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: scheme.onSurface.withValues(alpha: 0.15),
                  ),
                ),
                child: Icon(icon, size: 36, color: AppTokens.accent),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 歌单副标题：「N 首」，渠道提供播放量时附上。
String playlistSubtitle(int trackCount, {int? playCount}) {
  final count = '$trackCount 首';
  if (playCount == null || playCount <= 0) return count;
  final plays =
      playCount >= 10000
          ? '${(playCount / 10000).toStringAsFixed(playCount >= 100000 ? 0 : 1)} 万次播放'
          : '$playCount 次播放';
  return '$count · $plays';
}
