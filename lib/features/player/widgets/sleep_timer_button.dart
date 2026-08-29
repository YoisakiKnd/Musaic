import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/lifecycle/app_lifecycle.dart';
import '../../../core/theme/app_tokens.dart';
import '../domain/queue_logic.dart';
import '../player_notifier.dart';

/// 定时关闭按钮：倒计时 / 播完当前 / 再播 N 首。
///
/// 功耗计划 PW-02：倒计时激活期间由本按钮自持 1s 定时器、
/// 仅重建自身文本（旧实现以 1Hz setState 重建整个播放页）；
/// 应用不可见时（PW-03）暂停刷新，回前台自动恢复。
class SleepTimerButton extends ConsumerStatefulWidget {
  const SleepTimerButton({super.key});

  @override
  ConsumerState<SleepTimerButton> createState() => SleepTimerButtonState();
}

class SleepTimerButtonState extends ConsumerState<SleepTimerButton> {
  Timer? _ticker;

  /// 仅供测试观察（功耗 PW-02）：倒计时 ticker 是否存活。
  @visibleForTesting
  bool get debugIsTickerActive => _ticker != null;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker({required bool active}) {
    if (active && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!active && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(playerNotifierProvider.notifier);
    final endsAt = ref.watch(
      playerNotifierProvider.select((s) => s.sleepTimerEndsAt),
    );
    final songs = ref.watch(
      playerNotifierProvider.select((s) => s.sleepSongsRemaining),
    );
    final degraded = ref.watch(appUiDegradedProvider);

    _syncTicker(active: songs == null && endsAt != null && !degraded);

    String label;
    if (songs != null) {
      label = '还剩 $songs 首';
    } else if (endsAt != null) {
      final remaining = endsAt.difference(DateTime.now());
      label =
          remaining.isNegative
              ? '定时'
              : '剩余 ${QueueLogic.formatSleepRemaining(remaining)}';
    } else {
      label = '定时';
    }
    final active = endsAt != null || songs != null;

    return PopupMenuButton<String>(
      tooltip: '定时关闭',
      onSelected: (value) {
        switch (value) {
          case 'current':
            notifier.setSleepAfterSongs(1);
          case 'after3':
            notifier.setSleepAfterSongs(3);
          case 'after5':
            notifier.setSleepAfterSongs(5);
          case 'm15':
            notifier.setSleepTimer(const Duration(minutes: 15));
          case 'm30':
            notifier.setSleepTimer(const Duration(minutes: 30));
          case 'm60':
            notifier.setSleepTimer(const Duration(minutes: 60));
          default:
            notifier.clearSleep();
        }
      },
      itemBuilder:
          (context) => const [
            PopupMenuItem(value: 'current', child: Text('播完当前曲目后停止')),
            PopupMenuItem(value: 'after3', child: Text('再播 3 首后停止')),
            PopupMenuItem(value: 'after5', child: Text('再播 5 首后停止')),
            PopupMenuDivider(),
            PopupMenuItem(value: 'm15', child: Text('15 分钟后停止')),
            PopupMenuItem(value: 'm30', child: Text('30 分钟后停止')),
            PopupMenuItem(value: 'm60', child: Text('60 分钟后停止')),
            PopupMenuDivider(),
            PopupMenuItem(value: 'off', child: Text('关闭定时')),
          ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Icon(
              Icons.bedtime_rounded,
              size: 18,
              color:
                  active
                      ? AppTokens.accent
                      : Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
