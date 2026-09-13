import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/auth/auth_capability.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/features/library/data/library_providers.dart';
import 'package:musaic/features/library/data/library_repository.dart';
import 'package:musaic/features/player/player_notifier.dart';
import 'package:musaic/features/search/search_results_page.dart';

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
  }) async => const [];
  @override
  Future<Track> getTrackDetail(Track track) async => track;
  @override
  Future<ResolvedStream> resolveStream(Track track) =>
      throw UnimplementedError();
  @override
  Future<LyricBundle?> fetchLyrics(Track track) async => null;
}

Future<Map<String, String>> _noopReader() async => <String, String>{};

/// 可控渠道：首屏搜索结果 / 失败时机由测试控制。
class _ControllableSource extends _StubSource {
  _ControllableSource(super.id, super.name);

  final Completer<List<Track>> _firstSearch = Completer<List<Track>>();
  Object? _failure;

  void completeFirstSearch(List<Track> tracks) {
    _firstSearch.complete(tracks);
  }

  void failWith(Object error) => _failure = error;

  void recover() => _failure = null;

  @override
  Future<List<Track>> search(String query, {int limit = 30, int offset = 0}) {
    final failure = _failure;
    if (failure != null) {
      return Future.error(failure);
    }
    return _firstSearch.future;
  }
}

/// 跳过 audioHandler 初始化的播放器状态。
class _StubPlayerNotifier extends PlayerNotifier {
  @override
  PlayerState build() => const PlayerState();
}

Track _track(String id, String sourceId, String title) =>
    Track(id: id, sourceId: sourceId, title: title, artist: '歌手');

Future<void> _pumpPage(
  WidgetTester tester, {
  required Map<String, Object> results,
  required List<Track> merged,
  bool initialGrouped = false,
}) async {
  final registry =
      SourceRegistry()
        ..register(_StubSource('netease', '网易云音乐'))
        ..register(_StubSource('kugou', '酷狗音乐'));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sourceRegistryProvider.overrideWithValue(registry),
        playerNotifierProvider.overrideWith(_StubPlayerNotifier.new),
        // 收藏判定走 O(1) family provider，测试环境以桩替代（无 Hive）
        isFavoriteProvider.overrideWith((ref, key) => false),
      ],
      child: MaterialApp(
        home: SearchResultsPage(
          query: '测试',
          results: results,
          merged: merged,
          initialGrouped: initialGrouped,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('默认合并展示：无分组标题，全部曲目可见', (tester) async {
    await _pumpPage(
      tester,
      results: <String, Object>{
        'netease': <Track>[
          _track('1', 'netease', '网易云歌'),
          _track('2', 'netease', '网易云歌2'),
        ],
        'kugou': <Track>[_track('3', 'kugou', '酷狗歌')],
      },
      merged: <Track>[
        _track('1', 'netease', '网易云歌'),
        _track('3', 'kugou', '酷狗歌'),
        _track('2', 'netease', '网易云歌2'),
      ],
    );

    expect(find.text('网易云歌'), findsOneWidget);
    expect(find.text('酷狗歌'), findsOneWidget);
    // 分组标题的数量徽标不存在（合并模式）
    expect(find.text('2 首'), findsNothing);
    expect(find.text('1 首'), findsNothing);
  });

  testWidgets('分开展示：按渠道分组显示标题与数量', (tester) async {
    await _pumpPage(
      tester,
      results: <String, Object>{
        'netease': <Track>[
          _track('1', 'netease', '网易云歌'),
          _track('2', 'netease', '网易云歌2'),
        ],
        'kugou': <Track>[_track('3', 'kugou', '酷狗歌')],
      },
      merged: <Track>[
        _track('1', 'netease', '网易云歌'),
        _track('3', 'kugou', '酷狗歌'),
        _track('2', 'netease', '网易云歌2'),
      ],
    );

    // 切到分组模式
    await tester.tap(find.byTooltip('分开展示'));
    await tester.pumpAndSettle();

    // 分组节标题带数量徽标
    expect(find.text('2 首'), findsOneWidget);
    expect(find.text('1 首'), findsOneWidget);
    expect(find.text('网易云歌'), findsOneWidget);
    expect(find.text('酷狗歌'), findsOneWidget);
  });

  testWidgets('分开展示：失败渠道渲染错误提示', (tester) async {
    await _pumpPage(
      tester,
      results: <String, Object>{
        'netease': <Track>[_track('1', 'netease', '网易云歌')],
        'kugou': '搜索失败：网络异常',
      },
      merged: <Track>[_track('1', 'netease', '网易云歌')],
    );

    await tester.tap(find.byTooltip('分开展示'));
    await tester.pumpAndSettle();

    expect(find.text('酷狗音乐：搜索失败：网络异常'), findsOneWidget);
    expect(find.text('酷狗音乐'), findsNothing); // 失败渠道不渲染分组标题
  });

  // ---------- 计划 4.1：搜索页「结果展示」选择必须真正生效 ----------

  testWidgets('4.1 初始分组：搜索页选「分开展示」后结果页直接以分组开场', (tester) async {
    await _pumpPage(
      tester,
      initialGrouped: true,
      results: <String, Object>{
        'netease': <Track>[
          _track('1', 'netease', '网易云歌'),
          _track('2', 'netease', '网易云歌2'),
        ],
        'kugou': <Track>[_track('3', 'kugou', '酷狗歌')],
      },
      merged: <Track>[
        _track('1', 'netease', '网易云歌'),
        _track('3', 'kugou', '酷狗歌'),
        _track('2', 'netease', '网易云歌2'),
      ],
    );

    // 无需再点一次切换：分组标题与数量徽标已在首屏
    expect(find.text('2 首'), findsOneWidget);
    expect(find.text('1 首'), findsOneWidget);
    // 切换按钮此时应提示「合并展示」（说明当前处于分组态）
    expect(find.byTooltip('合并展示'), findsOneWidget);
  });

  testWidgets('4.1 初始合并：默认参数仍是合并展示（不改变既有行为）', (tester) async {
    await _pumpPage(
      tester,
      results: <String, Object>{
        'netease': <Track>[_track('1', 'netease', '网易云歌')],
        'kugou': <Track>[_track('3', 'kugou', '酷狗歌')],
      },
      merged: <Track>[
        _track('1', 'netease', '网易云歌'),
        _track('3', 'kugou', '酷狗歌'),
      ],
    );

    expect(find.text('1 首'), findsNothing);
    expect(find.byTooltip('分开展示'), findsOneWidget);
  });

  testWidgets('4.1 初始分组后仍可切回合并展示', (tester) async {
    await _pumpPage(
      tester,
      initialGrouped: true,
      results: <String, Object>{
        'netease': <Track>[_track('1', 'netease', '网易云歌')],
        'kugou': <Track>[_track('3', 'kugou', '酷狗歌')],
      },
      merged: <Track>[
        _track('1', 'netease', '网易云歌'),
        _track('3', 'kugou', '酷狗歌'),
      ],
    );

    expect(find.text('1 首'), findsNWidgets(2));

    await tester.tap(find.byTooltip('合并展示'));
    await tester.pumpAndSettle();

    expect(find.text('1 首'), findsNothing);
    expect(find.text('网易云歌'), findsOneWidget);
    expect(find.text('酷狗歌'), findsOneWidget);
  });

  testWidgets('分组模式切换回合并展示', (tester) async {
    await _pumpPage(
      tester,
      results: <String, Object>{
        'netease': <Track>[_track('1', 'netease', '网易云歌')],
        'kugou': <Track>[_track('3', 'kugou', '酷狗歌')],
      },
      merged: <Track>[
        _track('1', 'netease', '网易云歌'),
        _track('3', 'kugou', '酷狗歌'),
      ],
    );

    await tester.tap(find.byTooltip('分开展示'));
    await tester.pumpAndSettle();
    expect(find.text('1 首'), findsNWidgets(2));

    await tester.tap(find.byTooltip('合并展示'));
    await tester.pumpAndSettle();
    expect(find.text('1 首'), findsNothing);
  });

  testWidgets('增量搜索：渠道先到先展示，慢渠道后到后上屏（B19）', (tester) async {
    final slow = _ControllableSource('kugou', '酷狗音乐');
    final registry =
        SourceRegistry()
          ..register(_StubSource('netease', '网易云音乐'))
          ..register(slow);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceRegistryProvider.overrideWithValue(registry),
          playerNotifierProvider.overrideWith(_StubPlayerNotifier.new),
          isFavoriteProvider.overrideWith((ref, key) => false),
        ],
        child: MaterialApp(
          home: SearchResultsPage(
            query: '测试',
            results: <String, Object>{
              'netease': <Track>[_track('1', 'netease', '网易云歌')],
            },
            merged: <Track>[_track('1', 'netease', '网易云歌')],
            pendingSources: const ['kugou'],
          ),
        ),
      ),
    );
    await tester.pump();

    // 快渠道结果立即可见，慢渠道尚未上屏
    expect(find.text('网易云歌'), findsOneWidget);
    expect(find.text('慢渠道歌'), findsNothing);
    expect(find.text('正在搜索 1 个渠道…'), findsOneWidget);

    slow.completeFirstSearch([_track('9', 'kugou', '慢渠道歌')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('慢渠道歌'), findsOneWidget);
    expect(find.text('正在搜索 1 个渠道…'), findsNothing);
  });

  testWidgets('渠道失败后可独立重试（迭代计划 §10.6）', (tester) async {
    final failing = _ControllableSource('kugou', '酷狗音乐')
      ..failWith(const FormatException('bad payload'));
    final registry =
        SourceRegistry()
          ..register(_StubSource('netease', '网易云音乐'))
          ..register(failing);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceRegistryProvider.overrideWithValue(registry),
          playerNotifierProvider.overrideWith(_StubPlayerNotifier.new),
          isFavoriteProvider.overrideWith((ref, key) => false),
        ],
        child: const MaterialApp(
          home: SearchResultsPage(
            query: '测试',
            results: <String, Object>{},
            merged: <Track>[],
            pendingSources: ['kugou'],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 分组模式可见失败提示与重试按钮
    await tester.tap(find.byTooltip('分开展示'));
    await tester.pump();
    expect(find.text('酷狗音乐：搜索失败'), findsOneWidget);
    expect(find.text('慢渠道歌'), findsNothing);

    failing.recover();
    await tester.tap(find.byTooltip('重试 酷狗音乐'));
    await tester.pump();
    failing.completeFirstSearch([_track('9', 'kugou', '慢渠道歌')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('慢渠道歌'), findsOneWidget);
    expect(find.text('酷狗音乐：搜索失败'), findsNothing);
  });

  // ---------------------------------------------------------------------
  // 计划 2.4 验收：批量写歌单的 TextEditingController 生命周期。
  //
  // 旧实现在方法内 `final controller = TextEditingController();` 创建后
  // **从不 dispose**——静默泄漏（不崩溃，所以更难发现）。迁移到
  // `showTextInputDialog`（对话框自持 controller）后：
  //   - 方法内不再出现任何 TextEditingController 创建（见代码层审计）；
  //   - 成功路径：输入名称 → 创建歌单 + 批量加入；
  //   - 取消路径（空名提交 / 点取消）：不产生任何仓库写入。
  // ---------------------------------------------------------------------

  Future<void> pumpSaveAll(
    WidgetTester tester,
    _FakeLibraryRepository repository,
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
              'netease': <Track>[_track('1', 'netease', '网易云歌')],
            },
            merged: <Track>[_track('1', 'netease', '网易云歌')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('全部存为歌单：输入名称后创建并批量加入（2.4 成功路径）', (tester) async {
    final repository = _FakeLibraryRepository();
    await pumpSaveAll(tester, repository);

    await tester.tap(find.byTooltip('全部存为歌单'));
    await tester.pumpAndSettle();

    // 对话框由共享 widget 提供：标题 / 保存按钮来自调用方参数
    expect(find.text('保存全部结果为歌单'), findsOneWidget);
    expect(find.text('歌单名称（1 首）'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '通勤');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repository.createdPlaylists, ['通勤']);
    expect(repository.addedTo, ['通勤']);
    expect(find.textContaining('已保存「通勤」'), findsOneWidget);
  });

  testWidgets('全部存为歌单：空名提交不产生任何写入（2.4 取消路径）', (tester) async {
    final repository = _FakeLibraryRepository();
    await pumpSaveAll(tester, repository);

    await tester.tap(find.byTooltip('全部存为歌单'));
    await tester.pumpAndSettle();

    // 不输入任何内容直接保存 → trim 后为空 → 必须早退
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repository.createdPlaylists, isEmpty, reason: '空名不得创建歌单');
    expect(repository.addedTo, isEmpty, reason: '空名不得写入曲目');
  });

  testWidgets('全部存为歌单：点取消不产生任何写入（2.4 取消路径）', (tester) async {
    final repository = _FakeLibraryRepository();
    await pumpSaveAll(tester, repository);

    await tester.tap(find.byTooltip('全部存为歌单'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '不应生效');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(repository.createdPlaylists, isEmpty);
    expect(repository.addedTo, isEmpty);
  });
}

/// 内存假仓库：只记录批量存歌单相关的调用，其余成员一律抛错。
class _FakeLibraryRepository implements LibraryRepository {
  final List<String> createdPlaylists = <String>[];
  final List<String> addedTo = <String>[];

  @override
  Future<void> createPlaylist(String rawName) async {
    createdPlaylists.add(rawName);
  }

  @override
  Future<void> addManyToPlaylist(String rawName, Iterable<Track> tracks) async {
    addedTo.add(rawName);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('假仓库未实现：${invocation.memberName}');
}
