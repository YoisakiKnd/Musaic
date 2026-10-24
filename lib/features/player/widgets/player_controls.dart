import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_tokens.dart';
import '../domain/queue_logic.dart';
import '../player_notifier.dart';

/// 播放控制区（随机 / 上一首 / 播放暂停 / 下一首 / 循环模式）。
///
/// [compact] 用于底部播放条：按钮更小、间距更紧。
///
/// 只订阅控制区用得到的字段：此前 watch 完整播放状态，
/// 播放中每 100ms 的进度更新都会让整排按钮重建。
class PlayerControls extends ConsumerWidget {
  const PlayerControls({super.key, this.accentColor, this.compact = false});

  final Color? accentColor;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(playerNotifierProvider.notifier);
    final shuffleOn = ref.watch(
      playerNotifierProvider.select((s) => s.shuffleOn),
    );
    final mode = ref.watch(playerNotifierProvider.select((s) => s.mode));
    final hasQueue = ref.watch(
      playerNotifierProvider.select((s) => s.hasQueue),
    );
    final accent = accentColor ?? AppTokens.accent;
    final scheme = Theme.of(context).colorScheme;
    final dim = scheme.onSurface.withValues(alpha: 0.6);
    final skipSize = compact ? 26.0 : 36.0;
    final sideSize = compact ? 18.0 : 22.0;

    final children = <Widget>[
      IconButton(
        tooltip: '随机播放',
        onPressed: notifier.toggleShuffle,
        icon: Icon(
          Icons.shuffle_rounded,
          size: sideSize,
          color: shuffleOn ? accent : dim,
        ),
      ),
      IconButton(
        tooltip: '上一首',
        onPressed: hasQueue ? notifier.previous : null,
        icon: Icon(
          Icons.skip_previous_rounded,
          size: skipSize,
          color: scheme.onSurface,
        ),
      ),
      PlayPauseButton(size: compact ? 40 : 72),
      IconButton(
        tooltip: '下一首',
        onPressed: hasQueue ? notifier.next : null,
        icon: Icon(
          Icons.skip_next_rounded,
          size: skipSize,
          color: scheme.onSurface,
        ),
      ),
      IconButton(
        tooltip: switch (mode) {
          PlayMode.sequential => '顺序播放',
          PlayMode.loopAll => '列表循环',
          PlayMode.loopOne => '单曲循环',
        },
        onPressed:
            () => notifier.setMode(switch (mode) {
              PlayMode.sequential => PlayMode.loopAll,
              PlayMode.loopAll => PlayMode.loopOne,
              PlayMode.loopOne => PlayMode.sequential,
            }),
        icon: Icon(
          switch (mode) {
            PlayMode.sequential => Icons.repeat_rounded,
            PlayMode.loopAll => Icons.repeat_rounded,
            PlayMode.loopOne => Icons.repeat_one_rounded,
          },
          size: sideSize,
          color: mode == PlayMode.sequential ? dim : accent,
        ),
      ),
    ];

    if (compact) {
      return Row(mainAxisSize: MainAxisSize.min, children: children);
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: children,
    );
  }
}

/// 圆形播放/暂停按钮（播放页大号 / 播放条小号 / 迷你条共用）。
class PlayPauseButton extends ConsumerWidget {
  const PlayPauseButton({super.key, this.size = 72, this.filled = true});

  final double size;

  /// false 时只画图标（迷你条用），不画品牌色圆底。
  final bool filled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(playerNotifierProvider.notifier);
    final playing = ref.watch(playerNotifierProvider.select((s) => s.playing));
    final busy = ref.watch(playerNotifierProvider.select((s) => s.loading));
    final hasQueue = ref.watch(
      playerNotifierProvider.select((s) => s.hasQueue),
    );
    final fg = filled ? Colors.white : Theme.of(context).colorScheme.onSurface;

    return Tooltip(
      message: playing ? '暂停' : '播放',
      child: Material(
        color: filled ? AppTokens.accent : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: busy || !hasQueue ? null : notifier.toggle,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child:
                  busy
                      ? SizedBox(
                        width: size * 0.36,
                        height: size * 0.36,
                        child: CircularProgressIndicator(
                          strokeWidth: size > 50 ? 2.4 : 2,
                          color: fg.withValues(alpha: 0.9),
                        ),
                      )
                      : Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: size * 0.58,
                        color: fg,
                      ),
            ),
          ),
        ),
      ),
    );
  }
}
