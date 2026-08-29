import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/app/lifecycle/app_lifecycle.dart';

/// 应用生命周期桥接（功耗计划 PW-03）：UI 降级标志随前后台事件翻转。
void main() {
  testWidgets('AppLifecycleObserver 桥接 WidgetsBinding 事件', (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        child: AppLifecycleObserver(
          child: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    // 初始前台
    expect(container.read(appUiDegradedProvider), isFalse);

    // 模拟切后台
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(container.read(appUiDegradedProvider), isTrue);

    // hidden 同样视为降级
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(container.read(appUiDegradedProvider), isTrue);

    // 回前台
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(container.read(appUiDegradedProvider), isFalse);
  });
}
