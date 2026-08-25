import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_tokens.dart';
import '../domain/queue_logic.dart';
import '../player_notifier.dart';

/// 全屏播放器的控制区（模式 / 上一首 / 播放暂停 / 下一首）。
class PlayerControls extends ConsumerWidget {
  const PlayerControls({super.key, this.accentColor});

  final Color? accentColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(playerNotifierProvider.notifier);
    final state = ref.watch(playerNotifierProvider);
    final accent = accentColor ?? AppTokens.accent;
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          tooltip: '随机播放',
          onPressed: notifier.toggleShuffle,
          icon: Icon(
            Icons.shuffle_rounded,
            size: 22,
            color: state.shuffleOn ? accent : scheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        IconButton(
          tooltip: '上一首',
          onPressed: state.hasQueue ? notifier.previous : null,
          icon: Icon(
            Icons.skip_previous_rounded,
            size: 36,
            color: scheme.onSurface,
          ),
        ),
        _PlayPauseButton(state: state, accent: accent),
        IconButton(
          tooltip: '下一首',
          onPressed: state.hasQueue ? notifier.next : null,
          icon: Icon(
            Icons.skip_next_rounded,
            size: 36,
            color: scheme.onSurface,
          ),
        ),
        IconButton(
          tooltip: '播放模式',
          onPressed: () {
            switch (state.mode) {
              case PlayMode.sequential:
                notifier.setMode(PlayMode.loopAll);
              case PlayMode.loopAll:
                notifier.setMode(PlayMode.loopOne);
              case PlayMode.loopOne:
                notifier.setMode(PlayMode.sequential);
            }
          },
          icon: Icon(
            switch (state.mode) {
              PlayMode.sequential => Icons.format_list_numbered_rounded,
              PlayMode.loopAll => Icons.repeat_rounded,
              PlayMode.loopOne => Icons.repeat_one_rounded,
            },
            size: 22,
            color: state.mode == PlayMode.sequential
                ? scheme.onSurface.withValues(alpha: 0.6)
                : accent,
          ),
        ),
      ],
    );
  }
}

class _PlayPauseButton extends ConsumerWidget {
  const _PlayPauseButton({required this.state, required this.accent});

  final PlayerState state;
  final Color accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(playerNotifierProvider.notifier);
    final busy = state.loading;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: AppTokens.brandGradient,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: busy || !state.hasQueue ? null : notifier.toggle,
          child: SizedBox(
            width: 72,
            height: 72,
            child: Center(
              child: busy
                  ? SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    )
                  : Icon(
                      state.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 42,
                      color: Colors.white,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
