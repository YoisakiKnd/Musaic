import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/theme/app_tokens.dart';
import 'package:musaic/features/lyrics/application/lyrics_provider.dart';
import 'package:musaic/features/lyrics/presentation/lyrics_view.dart';
import 'package:musaic/features/player/player_notifier.dart';
import 'package:musaic/features/settings/settings_providers.dart';

/// `LyricsView` 的「加载失败」与「确实没有歌词」必须区分（计划 3.5）。
///
/// ## 被固化的缺陷
///
/// 视图原先把 `AsyncError` 与 `AsyncData(null)` 一起收进同一个 `_ =>` 分支，
/// 都渲染成「暂无歌词」。于是**真实的故障被陈述成事实**：用户以为这首歌
/// 本来就没有歌词，不会再重试，也无从知道是加载失败。
///
/// ## 固化后的契约
///
/// 1. `AsyncError` → 「歌词加载失败」+ 可点的「重试」（不是「暂无歌词」）；
/// 2. `AsyncData(null)`（渠道明确表示没有歌词）→ 「暂无歌词」；
/// 3. 空 bundle（`isEmpty`）→ 「暂无歌词」；
/// 4. 有内容 → 正常渲染歌词行；
/// 5. 点「重试」真的重新取一次歌词（不只是刷新界面）。
///
/// ## 为什么只测 UI 层
///
/// 各渠道适配器的 `fetchLyrics` 约定「失败返回 null 而不抛异常」
/// （歌词缺失不阻塞播放），所以正常路径下不该出现错误态。本测试用
/// provider override 人为制造 `AsyncError`，**不改适配器契约**——
/// 计划 3.5 明确限定只改 UI 层。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const track = Track(
    id: '1',
    sourceId: 'netease',
    title: '海阔天空',
    artist: 'Beyond',
  );

  LyricBundle bundle(List<String> texts) => LyricBundle(
    lines: <LyricLine>[
      for (var i = 0; i < texts.length; i++)
        LyricLine(text: texts[i], start: Duration(seconds: i * 5)),
    ],
  );

  /// 装载 LyricsView，歌词数据由 [fetch] 提供（可抛异常以模拟故障）。
  Future<int Function()> pumpView(
    WidgetTester tester,
    Future<LyricBundle?> Function(int call) fetch,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // 直接以 override 接管歌词来源：避免真实渠道与网络。
          lyricsProvider.overrideWith((ref, t) {
            calls++;
            return fetch(calls);
          }),
          // 偏移设置会经 appSettingsRepositoryProvider 读 Hive，这里用桩绕开。
          lyricOffsetMsProvider.overrideWith(_StubLyricOffsetNotifier.new),
          playerNotifierProvider.overrideWith(_StubPlayerNotifier.new),
        ],
        child: MaterialApp(
          theme: AppTokens.darkTheme,
          home: const Scaffold(body: LyricsView(track: track)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return () => calls;
  }

  group('歌词失败 vs 无歌词（3.5 回归）', () {
    testWidgets('加载失败显示「歌词加载失败」并给出重试，绝不谎称「暂无歌词」', (tester) async {
      await pumpView(tester, (call) async => throw StateError('解析器炸了'));

      expect(find.text('歌词加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(
        find.text('暂无歌词'),
        findsNothing,
        reason: '把故障说成「暂无歌词」会让用户以为这首歌本来就没有歌词',
      );
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    });

    testWidgets('渠道明确返回 null 时才是「暂无歌词」，且没有重试入口', (tester) async {
      await pumpView(tester, (call) async => null);

      expect(find.text('暂无歌词'), findsOneWidget);
      expect(find.text('歌词加载失败'), findsNothing);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('空 bundle 也是「暂无歌词」，不是失败', (tester) async {
      await pumpView(tester, (call) async => bundle(const <String>[]));

      expect(find.text('暂无歌词'), findsOneWidget);
      expect(find.text('歌词加载失败'), findsNothing);
    });

    testWidgets('有歌词时正常渲染歌词行', (tester) async {
      await pumpView(
        tester,
        (call) async => bundle(const <String>['今天我', '寒夜里看雪飘过']),
      );

      expect(find.text('今天我'), findsOneWidget);
      expect(find.text('寒夜里看雪飘过'), findsOneWidget);
      expect(find.text('暂无歌词'), findsNothing);
      expect(find.text('歌词加载失败'), findsNothing);
    });

    testWidgets('点「重试」真的重新拉取一次歌词，而不是只刷界面', (tester) async {
      // 第一次失败，第二次成功：重试必须触发真实的重取。
      final calls = await pumpView(
        tester,
        (call) async =>
            call == 1
                ? throw StateError('首次失败')
                : bundle(const <String>['今天我']),
      );

      expect(find.text('歌词加载失败'), findsOneWidget);
      expect(calls(), 1, reason: '首屏只取一次');

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(calls(), 2, reason: '重试必须真正重新调用 fetchLyrics');
      expect(find.text('今天我'), findsOneWidget);
      expect(find.text('歌词加载失败'), findsNothing);
    });
  });
}

/// 歌词偏移桩：绕开 appSettingsRepositoryProvider（其背后是 Hive Box）。
class _StubLyricOffsetNotifier extends LyricOffsetNotifier {
  @override
  int build() => 0;
}

/// 播放器桩：LyricsView 只读 position，无需真实音频通道。
class _StubPlayerNotifier extends PlayerNotifier {
  @override
  PlayerState build() => const PlayerState();
}
