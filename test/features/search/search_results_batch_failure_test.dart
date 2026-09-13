import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/logging/app_logger.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/auth/auth_capability.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/features/library/data/library_providers.dart';
import 'package:musaic/features/library/data/library_repository.dart';
import 'package:musaic/features/player/player_notifier.dart';
import 'package:musaic/features/search/search_results_page.dart';

/// 搜索结果页**批量写入失败反馈**的回归测试（计划 3.3）。
///
/// ## 被固化的缺陷
///
/// 三个批量写路径此前都是裸 `await`，**没有任何 try/catch**：
///
/// ```dart
/// await repository.addManyToPlaylist(name, tracks);   // 失败直接冒泡
/// await repository.toggleFavorite(track);             // 同上
/// ```
///
/// 写入失败（Hive 磁盘异常、存储满、key 冲突等）时异常冒泡到
/// Flutter 错误处理，界面上**既无 SnackBar 也无日志**——用户看到的是
/// 「点了没反应」，会以为操作没生效而反复点击，实际每次都失败。
///
/// ## 固化后的契约
///
/// 1. 失败必须落到**可见提示**（本文件的核心断言）；
/// 2. 失败必须**记日志**（`AppLog`，tag `MusaicSearch`），便于事后定位；
/// 3. 失败时**不得**进入「成功」分支（不清空选中态、不提示成功），
///    否则界面会谎报成功。
///
/// ## 为什么用内存假仓库
///
/// 同 `search_results_page_test.dart`：`testWidgets` 的伪造时钟会让真实
/// Hive 写盘永不完成，测试挂起且无断言失败。这里只验证
/// 「界面是否把失败正确地告诉了用户」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppLog.resetRing);

  Track song(String id) =>
      Track(id: id, sourceId: 'netease', title: '歌$id', artist: 'Beyond');

  /// 注入可控失败的仓库：默认全部写操作抛异常。
  Future<void> pumpPage(
    WidgetTester tester,
    _FailingLibraryRepository repository,
  ) async {
    final registry =
        SourceRegistry()..register(_StubSource('netease', '网易云音乐'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceRegistryProvider.overrideWithValue(registry),
          playerNotifierProvider.overrideWith(_StubPlayerNotifier.new),
          isFavoriteProvider.overrideWith((ref, key) => false),
          libraryRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          home: SearchResultsPage(
            query: '测试',
            results: <String, Object>{
              'netease': <Track>[song('1'), song('2')],
            },
            merged: <Track>[song('1'), song('2')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 进入多选并全选（三个批量动作都要求先有选中项）。
  Future<void> selectAll(WidgetTester tester) async {
    await tester.tap(find.byTooltip('多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全选'));
    await tester.pumpAndSettle();
  }

  /// 失败日志必须落盘，且带 MusaicSearch 标签。
  void expectLogged(String fragment) {
    final messages = AppLog.records.map((r) => r.message).join('\n');
    expect(
      messages,
      contains(fragment),
      reason: '批量写入失败必须记日志（AppLog），否则线上无从定位',
    );
    expect(
      AppLog.records.any((r) => r.tag == 'MusaicSearch'),
      isTrue,
      reason: '失败日志应带 MusaicSearch 标签',
    );
  }

  group('批量加入歌单失败（3.3）', () {
    testWidgets('写入失败给出「加入歌单失败，请重试」并记日志', (tester) async {
      final repository = _FailingLibraryRepository();
      await pumpPage(tester, repository);
      await selectAll(tester);

      await tester.tap(find.text('加入歌单'));
      await tester.pumpAndSettle();

      // 底部弹窗 → 新建歌单 → 输入名称确认
      await tester.tap(find.text('新建歌单'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '通勤');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      expect(
        find.text('加入歌单失败，请重试'),
        findsOneWidget,
        reason: '写入失败必须给出可见提示，不能静默',
      );
      expect(
        find.textContaining('已将'),
        findsNothing,
        reason: '失败时绝不能提示成功（谎报成功比不提示更糟）',
      );
      expectLogged('批量加入歌单失败');
    });

    testWidgets('失败后保持选中态，用户可直接重试', (tester) async {
      final repository = _FailingLibraryRepository();
      await pumpPage(tester, repository);
      await selectAll(tester);

      await tester.tap(find.text('加入歌单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建歌单'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '通勤');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      // 仍处于多选态：批量操作栏可见，选中项未被清空
      expect(
        find.byTooltip('全选'),
        findsOneWidget,
        reason: '失败后应保留多选态，让用户能直接重试而不是重新勾选',
      );
    });
  });

  group('批量收藏失败（3.3）', () {
    testWidgets('全部失败给出「收藏失败，请重试」', (tester) async {
      final repository = _FailingLibraryRepository();
      await pumpPage(tester, repository);
      await selectAll(tester);

      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();

      expect(find.text('收藏失败，请重试'), findsOneWidget);
      expect(find.textContaining('已收藏'), findsNothing);
      expectLogged('批量收藏失败');
    });

    testWidgets('部分成功时提示已成功的数量，不谎报全成功', (tester) async {
      // 第一首成功、第二首失败
      final repository = _FailingLibraryRepository(failAfterFavorites: 1);
      await pumpPage(tester, repository);
      await selectAll(tester);

      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('部分收藏成功（1/2）'),
        findsOneWidget,
        reason: '部分成功必须如实告知进度，便于用户只重试剩下的',
      );
      expect(find.text('已收藏 2 首'), findsNothing);
      expectLogged('批量收藏失败');
    });
  });

  group('全部存为歌单失败（3.3）', () {
    testWidgets('创建歌单失败给出「保存歌单失败，请重试」', (tester) async {
      final repository = _FailingLibraryRepository();
      await pumpPage(tester, repository);

      await tester.tap(find.byTooltip('全部存为歌单'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '通勤');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('保存歌单失败，请重试'), findsOneWidget);
      expect(find.textContaining('已保存'), findsNothing, reason: '失败时不得提示「已保存」');
      expectLogged('保存歌单失败');
    });

    testWidgets('只有批量加入失败时同样给出提示', (tester) async {
      // createPlaylist 成功、addManyToPlaylist 失败
      final repository = _FailingLibraryRepository(failOnAddMany: true);
      await pumpPage(tester, repository);

      await tester.tap(find.byTooltip('全部存为歌单'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '通勤');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('保存歌单失败，请重试'), findsOneWidget);
      expectLogged('保存歌单失败');
    });
  });
}

/// 可控失败的假仓库：只实现本文件用到的成员，其余经 [noSuchMethod] 抛错，
/// 界面一旦新增调用会立刻暴露。
class _FailingLibraryRepository implements LibraryRepository {
  _FailingLibraryRepository({
    this.failOnAddMany = false,
    this.failAfterFavorites,
  });

  /// true 时 `addManyToPlaylist` 抛错（用于「创建成功但批量加入失败」）。
  final bool failOnAddMany;

  /// 前 N 次 `toggleFavorite` 成功、之后失败；null 表示全部失败。
  final int? failAfterFavorites;

  int _favoriteCalls = 0;

  @override
  List<String> get playlistNames => const <String>[];

  @override
  bool isFavorite(String trackKey) => false;

  @override
  Future<void> createPlaylist(String rawName) async {
    if (!failOnAddMany) {
      throw StateError('模拟创建歌单失败');
    }
  }

  @override
  Future<void> addManyToPlaylist(String rawName, Iterable<Track> tracks) async {
    throw StateError('模拟批量加入歌单失败');
  }

  @override
  Future<bool> toggleFavorite(Track track) async {
    final allowed = failAfterFavorites;
    if (allowed != null && _favoriteCalls < allowed) {
      _favoriteCalls++;
      return true;
    }
    throw StateError('模拟收藏写入失败');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('假仓库未实现：${invocation.memberName}');
}

/// 跳过 audioHandler 初始化的播放器状态。
class _StubPlayerNotifier extends PlayerNotifier {
  @override
  PlayerState build() => const PlayerState();
}

/// 极简渠道桩：本文件不关心搜索行为，只用于让结果页拿到曲目。
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
