import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/auth/auth_capability.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/theme/app_tokens.dart';
import 'package:musaic/features/library/data/library_providers.dart';
import 'package:musaic/features/player/player_notifier.dart';
import 'package:musaic/features/search/data/search_history_repository.dart';
import 'package:musaic/features/search/search_page.dart';

/// 搜索页提交语义（计划 3.1 空提交反馈 / 3.2 重复提交防抖）。
///
/// ## 被固化的两个缺陷
///
/// **3.1**：`_submit` 对空/纯空白输入是静默 `return`。用户按了回车或点了
/// 搜索按钮却「什么都没发生」，会反复重试并怀疑输入法或按钮坏了。
///
/// **3.2**：结果页是独立的 `Navigator.push` 页面，搜索结果由结果页自己
/// 流式接收；连点搜索按钮或连按回车会叠加出多个结果页（返回要退好几层），
/// 且每次都重复请求所有渠道。
///
/// ## 固化后的契约
///
/// 1. 空输入提交 → 明确提示「请输入搜索关键词」，且**不跳转**结果页；
/// 2. 纯空白输入同 1（trim 之后判空）；
/// 3. 窗口内同一关键词重复提交 → 只跳转一次；
/// 4. 换关键词不受防抖影响（防抖只认「同一关键词」）；
/// 5. 窗口过后重搜同一关键词仍然生效（防抖不是永久封禁）。
///
/// 跳转次数用 [NavigatorObserver] 计数，而不是断言界面文案——
/// 「是否多开了一层结果页」正是用户要退好几层这个真实痛点。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_RouteCounter> pumpSearchPage(WidgetTester tester) async {
    final counter = _RouteCounter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // 渠道：两个空实现即可，本测试只关心「是否发起提交」。
          sourceRegistryProvider.overrideWithValue(
            SourceRegistry()
              ..register(_StubSource('netease', '网易云'))
              ..register(_StubSource('qqmusic', 'QQ 音乐')),
          ),
          // 历史仓库：initState 会同步 load()，用内存假实现避开 Hive。
          searchHistoryRepositoryProvider.overrideWithValue(
            _FakeSearchHistoryRepository(),
          ),
          // 结果页会 watch 这两个 provider。
          playerNotifierProvider.overrideWith(_StubPlayerNotifier.new),
          isFavoriteProvider.overrideWith((ref, key) => false),
        ],
        child: MaterialApp(
          theme: AppTokens.darkTheme,
          navigatorObservers: [counter],
          home: const SearchPage(),
        ),
      ),
    );
    // initState 的 postFrameCallback 里才置 _uiReady。
    await tester.pumpAndSettle();
    return counter;
  }

  /// 首个路由（SearchPage 自身）占用一次 didPush，计数时要扣掉。
  int pushedRoutes(_RouteCounter counter) => counter.pushes - 1;

  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.byTooltip('搜索'));
  }

  group('搜索提交反馈与防抖（3.1 / 3.2 回归）', () {
    testWidgets('3.1 空输入提交给出「请输入搜索关键词」，且不跳转结果页', (tester) async {
      final counter = await pumpSearchPage(tester);

      await submit(tester);
      await tester.pumpAndSettle();

      expect(find.text('请输入搜索关键词'), findsOneWidget);
      expect(pushedRoutes(counter), 0, reason: '空关键词不该打开结果页——那会是一个永远空的结果页');
    });

    testWidgets('3.1 纯空白输入同样被拦截（trim 后判空）', (tester) async {
      final counter = await pumpSearchPage(tester);

      await tester.enterText(find.byType(TextField), '    ');
      await submit(tester);
      await tester.pumpAndSettle();

      expect(find.text('请输入搜索关键词'), findsOneWidget);
      expect(pushedRoutes(counter), 0);
    });

    testWidgets('3.2 窗口内重复提交同一关键词只跳转一次', (tester) async {
      final counter = await pumpSearchPage(tester);

      await tester.enterText(find.byType(TextField), '海阔天空');

      // 直接调用按钮回调，而不是 tester.tap 两次。
      //
      // 原因：第一次提交会在同一微任务里 push 结果页，第二次 tap 的
      // 命中测试会落到**盖在上面的结果页**上（实测 tap 报
      // "hit test result ... RenderPointerListener"），于是本用例会
      // 「因为按钮点不到」而通过，而不是因为防抖生效——那是假通过。
      // 直接调回调才能确保两次提交都真正进入 _submit。
      final searchButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded),
      );
      searchButton.onPressed!();
      searchButton.onPressed!();
      await tester.pumpAndSettle();

      expect(pushedRoutes(counter), 1, reason: '连点搜索按钮不得叠加出多个结果页（用户要退好几层）');
    });

    testWidgets('3.2 换关键词不受防抖影响', (tester) async {
      final counter = await pumpSearchPage(tester);

      await tester.enterText(find.byType(TextField), '海阔天空');
      await submit(tester);
      await tester.pumpAndSettle();
      expect(pushedRoutes(counter), 1);

      // 退回搜索页后**立即**换关键词再提交：两次提交仍落在 600ms 窗口内，
      // 因此若防抖只看时间、不看关键词，第二次会被吞掉（本用例即失败）。
      // 必须用 pageBack 而不是直接 enterText：结果页已盖住搜索页，
      // 覆盖状态下 enterText 改不动输入框，会让本用例测不到防抖。
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '光辉岁月');
      await submit(tester);
      await tester.pumpAndSettle();

      expect(pushedRoutes(counter), 2, reason: '防抖只针对同一关键词，换词必须照常搜索');
    });

    testWidgets('3.2 窗口过后重搜同一关键词仍然生效（防抖不是永久封禁）', (tester) async {
      final counter = await pumpSearchPage(tester);

      await tester.enterText(find.byType(TextField), '海阔天空');
      await submit(tester);
      await tester.pumpAndSettle();
      expect(pushedRoutes(counter), 1);

      // 退回搜索页，并真实等待超过 600ms 的防抖窗口。
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 700)),
      );

      await submit(tester);
      await tester.pumpAndSettle();

      expect(
        pushedRoutes(counter),
        2,
        reason: '过了防抖窗口重搜同一关键词必须正常发起，否则等于封禁该关键词',
      );
    });
  });
}

/// 路由计数：`didPush` 次数即「结果页被打开了几次」。
class _RouteCounter extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    super.didPush(route, previousRoute);
  }
}

/// 空渠道桩：只满足注册表，不产生任何结果。
class _StubSource extends MusicSource {
  _StubSource(this._id, this._name) : super(credentialReader: _noopReader);

  final String _id;
  final String _name;

  @override
  String get sourceId => _id;

  @override
  String get displayName => _name;

  @override
  AuthCapability get authCapability => AuthCapability.noAuth;

  @override
  Future<List<Track>> search(
    String query, {
    int limit = 30,
    int offset = 0,
  }) async => const <Track>[];

  @override
  Future<Track> getTrackDetail(Track track) async => track;

  @override
  Future<ResolvedStream> resolveStream(Track track) =>
      throw UnimplementedError();

  @override
  Future<LyricBundle?> fetchLyrics(Track track) async => null;
}

Future<Map<String, String>> _noopReader() async => <String, String>{};

/// 内存搜索历史：避开 Hive（testWidgets 的伪造时钟会让真实写盘挂起）。
class _FakeSearchHistoryRepository implements SearchHistoryRepository {
  final List<String> _keywords = <String>[];

  @override
  List<String> load() => List<String>.unmodifiable(_keywords);

  @override
  Future<List<String>> add(String keyword) async {
    _keywords.remove(keyword);
    _keywords.insert(0, keyword);
    return load();
  }

  @override
  Future<List<String>> clear() async {
    _keywords.clear();
    return const <String>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('假搜索历史仓库未实现：${invocation.memberName}');
}

/// 播放器桩：结果页会读它，但本测试不播放。
class _StubPlayerNotifier extends PlayerNotifier {
  @override
  PlayerState build() => const PlayerState();
}
