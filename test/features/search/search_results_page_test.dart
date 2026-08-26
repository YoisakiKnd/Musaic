import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/features/auth/domain/auth_capability.dart';
import 'package:musaic/features/lyrics/domain/lyric_bundle.dart';
import 'package:musaic/features/library/data/library_providers.dart';
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
  Future<List<Track>> search(String query,
          {int limit = 30, int offset = 0}) async =>
      const [];
  @override
  Future<Track> getTrackDetail(Track track) async => track;
  @override
  Future<ResolvedStream> resolveStream(Track track) =>
      throw UnimplementedError();
  @override
  Future<LyricBundle?> fetchLyrics(Track track) async => null;
}

Future<Map<String, String>> _noopReader() async => <String, String>{};

/// 跳过 audioHandler 初始化的播放器状态。
class _StubPlayerNotifier extends PlayerNotifier {
  @override
  PlayerState build() => const PlayerState();
}

Track _track(String id, String sourceId, String title) => Track(
      id: id,
      sourceId: sourceId,
      title: title,
      artist: '歌手',
    );

Future<void> _pumpPage(
  WidgetTester tester, {
  required Map<String, Object> results,
  required List<Track> merged,
}) async {
  final registry = SourceRegistry()
    ..register(_StubSource('netease', '网易云音乐'))
    ..register(_StubSource('kugou', '酷狗音乐'));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sourceRegistryProvider.overrideWithValue(registry),
        playerNotifierProvider.overrideWith(_StubPlayerNotifier.new),
        favoritesProvider.overrideWith((ref) => Stream.value(const <Track>[])),
      ],
      child: MaterialApp(
        home: SearchResultsPage(
          query: '测试',
          results: results,
          merged: merged,
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
        'kugou': <Track>[
          _track('3', 'kugou', '酷狗歌'),
        ],
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
        'kugou': <Track>[
          _track('3', 'kugou', '酷狗歌'),
        ],
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
        'netease': <Track>[
          _track('1', 'netease', '网易云歌'),
        ],
        'kugou': '搜索失败：网络异常',
      },
      merged: <Track>[
        _track('1', 'netease', '网易云歌'),
      ],
    );

    await tester.tap(find.byTooltip('分开展示'));
    await tester.pumpAndSettle();

    expect(find.text('酷狗音乐：搜索失败：网络异常'), findsOneWidget);
    expect(find.text('酷狗音乐'), findsNothing); // 失败渠道不渲染分组标题
  });

  testWidgets('分组模式切换回合并展示', (tester) async {
    await _pumpPage(
      tester,
      results: <String, Object>{
        'netease': <Track>[
          _track('1', 'netease', '网易云歌'),
        ],
        'kugou': <Track>[
          _track('3', 'kugou', '酷狗歌'),
        ],
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
}
