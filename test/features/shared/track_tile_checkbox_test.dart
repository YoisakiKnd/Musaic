import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/theme/app_tokens.dart';
import 'package:musaic/features/library/data/library_providers.dart';
import 'package:musaic/features/player/player_notifier.dart';
import 'package:musaic/features/shared/widgets/track_tile.dart';

/// `TrackTile` 多选框的解耦回归测试（计划 4.3）。
///
/// ## 被固化的缺陷
///
/// 勾选框此前把回调**借道** `onTapOverride`：
///
/// ```dart
/// Checkbox(value: leadingCheckbox, onChanged: (_) => onTapOverride?.call())
/// ```
///
/// 于是「传了 `leadingCheckbox` 却没传 `onTapOverride`」会得到一个
/// **看起来可点、点了毫无反应**的勾选框——界面在骗用户。
///
/// ## 固化后的契约
///
/// 1. `onCheckboxChanged` 独立生效，不依赖 `onTapOverride`；
/// 2. 未提供 `onCheckboxChanged` 时回落到 `onTapOverride`（兼容旧调用）；
/// 3. 两者都为空时勾选框**显式禁用**（`onChanged == null`，置灰），
///    让「不可用」可见，而不是静默失效。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Track track() => const Track(
    id: '1',
    sourceId: 'netease',
    title: '海阔天空',
    artist: 'Beyond',
  );

  Widget host({
    bool? leadingCheckbox,
    VoidCallback? onTapOverride,
    VoidCallback? onCheckboxChanged,
  }) {
    return ProviderScope(
      overrides: [
        // 渠道徽标解析走注册表；空注册表避免沿组合根去要 accountRepository。
        sourceRegistryProvider.overrideWithValue(SourceRegistry()),
        playerNotifierProvider.overrideWith(_StubPlayerNotifier.new),
        // 收藏判定走 O(1) family provider，测试环境以桩替代（无 Hive）。
        isFavoriteProvider.overrideWith((ref, key) => false),
      ],
      child: MaterialApp(
        theme: AppTokens.darkTheme,
        home: Scaffold(
          body: TrackTile(
            track: track(),
            queue: <Track>[track()],
            leadingCheckbox: leadingCheckbox,
            onTapOverride: onTapOverride,
            onCheckboxChanged: onCheckboxChanged,
          ),
        ),
      ),
    );
  }

  group('多选框回调解耦（4.3）', () {
    testWidgets('onCheckboxChanged 独立生效，不依赖 onTapOverride', (tester) async {
      var checkboxTaps = 0;
      const rowTaps = 0;

      await tester.pumpWidget(
        host(
          leadingCheckbox: false,
          // 关键：**不传** onTapOverride —— 旧实现下勾选框会彻底失效
          onCheckboxChanged: () => checkboxTaps++,
        ),
      );
      await tester.pumpAndSettle();

      // 行本身仍可点（回落到默认播放行为），但这里只关心勾选框
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();

      expect(checkboxTaps, 1, reason: '勾选框必须有自己的回调通道，不能借道 onTapOverride');
      expect(rowTaps, 0, reason: '未提供 onTapOverride 时不应被勾选框间接触发');
    });

    testWidgets('未提供 onCheckboxChanged 时回落到 onTapOverride', (tester) async {
      var rowTaps = 0;

      await tester.pumpWidget(
        host(leadingCheckbox: false, onTapOverride: () => rowTaps++),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();

      expect(rowTaps, 1, reason: '旧调用方只传 onTapOverride，行为必须保持兼容');
    });

    testWidgets('两个回调都为空时勾选框显式禁用，而不是静默失效', (tester) async {
      await tester.pumpWidget(host(leadingCheckbox: false));
      await tester.pumpAndSettle();

      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(
        checkbox.onChanged,
        isNull,
        reason:
            '无回调时必须禁用（置灰），让「不可用」对用户可见；'
            '旧实现传入非空闭包，勾选框看着可点却毫无反应',
      );
    });

    testWidgets('onCheckboxChanged 优先于 onTapOverride', (tester) async {
      var checkboxTaps = 0;
      var rowTaps = 0;

      await tester.pumpWidget(
        host(
          leadingCheckbox: true,
          onTapOverride: () => rowTaps++,
          onCheckboxChanged: () => checkboxTaps++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();

      expect(checkboxTaps, 1);
      expect(rowTaps, 0, reason: '两者同时提供时，勾选框走自己的回调');
    });
  });
}

/// 播放器桩：避免真实 just_audio 平台通道调用（单元环境会挂起 25s）。
class _StubPlayerNotifier extends PlayerNotifier {
  @override
  PlayerState build() => const PlayerState();
}
