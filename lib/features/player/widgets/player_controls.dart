import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musaic/features/player/player_notifier.dart';
import 'package:musaic/core/theme/app_tokens.dart';

class PlayerControls extends ConsumerWidget {
  const PlayerControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerState = ref.watch(playerNotifierProvider);
    final notifier = ref.read(playerNotifierProvider.notifier);
    final isPlaying = playerState.isPlaying;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          onPressed: () => notifier.setPlayMode(PlayMode.sequence),
          icon: Icon(
            Icons.repeat,
            color: playerState.playMode == PlayMode.sequence
                ? Theme.of(context).colorScheme.primary
                : AppTokens.textSecondary,
          ),
        ),
        IconButton.filled(
          onPressed: () => notifier.previous(),
          icon: const Icon(Icons.skip_previous),
        ),
        FloatingActionButton.large(
          onPressed: () {
            if (isPlaying) {
              notifier.pause();
            } else {
              notifier.play();
            }
          },
          child: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
        ),
        IconButton.filled(
          onPressed: () => notifier.next(),
          icon: const Icon(Icons.skip_next),
        ),
        IconButton(
          onPressed: () => notifier.setPlayMode(PlayMode.repeatOne),
          icon: Icon(
            Icons.repeat_one,
            color: playerState.playMode == PlayMode.repeatOne
                ? Theme.of(context).colorScheme.primary
                : AppTokens.textSecondary,
          ),
        ),
      ],
    );
  }
}
