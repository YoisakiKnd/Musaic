import 'dart:io' show File;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_tokens.dart';
import '../settings/settings_providers.dart';
import 'player_notifier.dart';

/// 迷你播放条（Master Plan §8：常驻悬浮层，每屏唯一实时模糊区）。
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerNotifierProvider.select((s) => s.current));
    if (track == null) return const SizedBox.shrink();

    final playing =
        ref.watch(playerNotifierProvider.select((s) => s.playing));
    final position =
        ref.watch(playerNotifierProvider.select((s) => s.position));
    final duration =
        ref.watch(playerNotifierProvider.select((s) => s.duration));
    final notifier = ref.read(playerNotifierProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    final progress = (duration != null && duration.inMilliseconds > 0)
        ? (position.inMilliseconds / duration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;

    final glass = ref.watch(enableGlassProvider);

    Widget body = Container(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: glass ? 0.72 : 0.97),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: progress,
            minHeight: 2,
            backgroundColor: Colors.transparent,
            valueColor:
                const AlwaysStoppedAnimation<Color>(AppTokens.accent),
          ),
          ListTile(
            dense: true,
            onTap: () => context.push('/player'),
            leading: _Cover(coverUrl: track.coverUrl),
            title: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${track.artist}${track.album == null ? '' : ' · ${track.album}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: notifier.toggle,
                  icon: Icon(
                    playing
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_fill_rounded,
                    size: 34,
                  ),
                ),
                IconButton(
                  onPressed: notifier.next,
                  icon: const Icon(Icons.skip_next_rounded),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (glass) {
      // 性能预算 §10.2：全屏唯一实时模糊区，外包 RepaintBoundary
      body = ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: body,
        ),
      );
    } else {
      body = ClipRRect(borderRadius: BorderRadius.circular(20), child: body);
    }

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: body,
      ),
    );
  }
}

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
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(Uri.parse(url).toFilePath()),
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => placeholder,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: CachedNetworkImage(
        imageUrl: url,
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
