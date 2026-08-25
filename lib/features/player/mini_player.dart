import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_tokens.dart';
import 'player_notifier.dart';

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerState = ref.watch(playerNotifierProvider);
    final track = playerState.currentTrack;
    final isPlaying = playerState.isPlaying;

    if (track == null) {
      return const SizedBox.shrink();
    }

    return AnimatedSlide(
      offset: Offset.zero,
      duration: AppTokens.durationNormal,
      curve: AppTokens.curveDecelerate,
      child: Container(
        height: AppTokens.miniPlayerHeight,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        decoration: BoxDecoration(
          color: AppTokens.surfaceSecondary,
          borderRadius: AppTokens.borderRadiusMedium,
          boxShadow: AppTokens.glassShadow,
        ),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  track.displayTitle,
                  style: Theme.of(context).textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            IconButton(
              onPressed: () {
                if (isPlaying) {
                  ref.read(playerNotifierProvider.notifier).pause();
                } else {
                  ref.read(playerNotifierProvider.notifier).play();
                }
              },
              icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
            ),
          ],
        ),
      ),
    );
  }
}
