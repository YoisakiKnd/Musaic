import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musaic/core/theme/app_tokens.dart';
import 'package:musaic/features/player/player_notifier.dart';

class PlayerProgressBar extends ConsumerWidget {
  const PlayerProgressBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerState = ref.watch(playerNotifierProvider);
    final position = playerState.position;
    final duration = playerState.duration;

    return Slider(
      value: position.inMilliseconds.clamp(
        0,
        max(duration.inMilliseconds, 1),
      ).toDouble(),
      min: 0.0,
      max: max(duration.inMilliseconds.toDouble(), 1.0),
      onChanged: (value) {
        ref.read(playerNotifierProvider.notifier).seek(
              Duration(milliseconds: value.toInt()),
            );
      },
      activeColor: Theme.of(context).colorScheme.primary,
      inactiveColor: AppTokens.surfaceTertiary,
    );
  }
}
