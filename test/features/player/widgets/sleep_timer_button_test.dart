import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/app/lifecycle/app_lifecycle.dart';
import 'package:musaic/features/player/domain/queue_logic.dart';
import 'package:musaic/features/player/player_notifier.dart';
import 'package:musaic/features/player/widgets/sleep_timer_button.dart';

/// 睡眠倒计时按钮的刷新纪律（功耗计划 PW-02）：
/// 倒计时期间仅本按钮每秒重建，应用不可见时暂停刷新。
void main() {
  testWidgets('倒计时激活：文本每秒走字', (tester) async {
    final endsAt = DateTime.now().add(const Duration(seconds: 90));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerNotifierProvider.overrideWith(
            () => _SleepStubNotifier(endsAt: endsAt),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: SleepTimerButton())),
      ),
    );
    final expected = QueueLogic.formatSleepRemaining(
      endsAt.difference(DateTime.now()),
    );
    expect(find.text('剩余 $expected'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    final afterTwoSeconds = QueueLogic.formatSleepRemaining(
      endsAt.difference(DateTime.now()),
    );
    expect(find.text('剩余 $afterTwoSeconds'), findsOneWidget);
  });

  testWidgets('未设定定时：无倒计时文本', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerNotifierProvider.overrideWith(_SleepStubNotifier.new),
        ],
        child: const MaterialApp(home: Scaffold(body: SleepTimerButton())),
      ),
    );
    expect(find.text('定时'), findsOneWidget);
    expect(find.textContaining('剩余'), findsNothing);
  });

  testWidgets('应用不可见（PW-03）：倒计时 ticker 取消，回前台恢复', (tester) async {
    final endsAt = DateTime.now().add(const Duration(minutes: 15));
    late BuildContext capturedContext;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerNotifierProvider.overrideWith(
            () => _SleepStubNotifier(endsAt: endsAt),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                capturedContext = context;
                return const SleepTimerButton();
              },
            ),
          ),
        ),
      ),
    );
    final state = tester.state<SleepTimerButtonState>(
      find.byType(SleepTimerButton),
    );
    expect(state.debugIsTickerActive, isTrue, reason: '倒计时激活期间 ticker 存活');

    // 模拟进入后台：ticker 应立即取消
    ProviderScope.containerOf(
      capturedContext,
      listen: false,
    ).read(appLifecycleStateProvider.notifier).update(AppLifecycleState.paused);
    await tester.pump();
    expect(state.debugIsTickerActive, isFalse, reason: '后台不刷新倒计时');

    // 回前台：恢复刷新
    ProviderScope.containerOf(capturedContext, listen: false)
        .read(appLifecycleStateProvider.notifier)
        .update(AppLifecycleState.resumed);
    await tester.pump();
    expect(state.debugIsTickerActive, isTrue);
  });
}

class _SleepStubNotifier extends PlayerNotifier {
  _SleepStubNotifier({this.endsAt});

  final DateTime? endsAt;

  @override
  PlayerState build() =>
      PlayerState(sleepTimerEndsAt: endsAt, sleepSongsRemaining: null);
}
