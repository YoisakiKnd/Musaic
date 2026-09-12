import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/theme/app_tokens.dart';
import 'package:musaic/features/library/data/library_repository.dart';
import 'package:musaic/features/library/widgets/add_to_playlist_sheet.dart';
import 'package:musaic/features/shared/widgets/track_tile.dart';
import 'package:musaic/features/player/audio_handler.dart';
import 'package:musaic/features/player/data/resume_repository.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';

/// 「加入歌单」入口的 **UI 接线测试**（日常可用性计划 D2）。
///
/// ## 分层说明
///
/// 本文件只验证「界面是否调用了正确的仓库方法、是否给出正确反馈」，
/// 因此仓库用**内存假实现**，不触碰 Hive。
///
/// 真实落盘正确性由 `test/e2e/main_flow_test.dart` 覆盖（普通 `test()`，
/// 真实时钟下跑真实 Hive）。
///
/// 这样分层的原因：`testWidgets` 使用伪造时钟，真实 Hive 写盘在其中
/// **永不完成**，会表现为「测试跑完但不结束」而被框架超时杀掉——
/// 排查代价极高（本计划踩过）。把真实 IO 留给普通 `test()` 是唯一可靠做法。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLibraryRepository repository;
  late Directory tempDir;
  late Box<String> resumeBox;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_sheet_test');
    Hive.init(tempDir.path);
    resumeBox = await Hive.openBox<String>('sheet_resume');
  });

  tearDownAll(() async {
    if (resumeBox.isOpen) await resumeBox.close();
    await Hive.close();
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  setUp(() {
    repository = _FakeLibraryRepository();
  });

  Track song(String id, {String sourceId = 'netease'}) =>
      Track(id: id, sourceId: sourceId, title: '海阔天空', artist: 'Beyond');

  Widget host(Widget child) {
    return ProviderScope(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repository),
        // TrackTile 会解析渠道以显示徽标；直接注入空注册表，
        // 避免它沿组合根去要 accountRepository（未启动时必然抛错）。
        sourceRegistryProvider.overrideWithValue(SourceRegistry()),
        // TrackTile 会读取播放状态，需注入桩，避免触碰音频栈
        audioHandlerProvider.overrideWithValue(
          MusaicAudioHandler(player: _StubPlayer()),
        ),
        resumeRepositoryProvider.overrideWithValue(
          ResumeRepository(box: resumeBox),
        ),
      ],
      child: MaterialApp(
        theme: AppTokens.darkTheme,
        home: Scaffold(body: child),
      ),
    );
  }

  group('AddToPlaylistSheet 接线', () {
    testWidgets('无歌单时给出引导而非空白', (tester) async {
      await tester.pumpWidget(
        host(
          Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => AddToPlaylistSheet.show(context, [song('1')]),
                  child: const Text('打开'),
                ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('还没有歌单，先新建一个吧'), findsOneWidget);
      expect(find.text('新建歌单'), findsOneWidget);
    });

    testWidgets('已有歌单时列出并显示曲目数', (tester) async {
      repository
        ..seedPlaylist('通勤', [song('1')])
        ..seedPlaylist('健身', [song('2'), song('3')]);

      await tester.pumpWidget(
        host(
          Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => AddToPlaylistSheet.show(context, [song('9')]),
                  child: const Text('打开'),
                ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('通勤'), findsOneWidget);
      expect(find.text('健身'), findsOneWidget);
      expect(find.text('1 首'), findsOneWidget);
      expect(find.text('2 首'), findsOneWidget);
    });

    testWidgets('选择既有歌单会调用仓库并给出成功反馈', (tester) async {
      repository.seedPlaylist('通勤', const []);

      await tester.pumpWidget(
        host(
          Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => AddToPlaylistSheet.show(context, [song('7')]),
                  child: const Text('打开'),
                ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('通勤'));
      await tester.pumpAndSettle();

      expect(repository.addedTo, contains('通勤'));
      expect(repository.addedTracks['通勤']!.map((t) => t.key), ['netease:7']);
      expect(find.textContaining('已加入'), findsOneWidget);
    });

    testWidgets('多选曲目时标题显示数量，并批量写入', (tester) async {
      repository.seedPlaylist('批量', const []);

      await tester.pumpWidget(
        host(
          Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => AddToPlaylistSheet.show(context, [
                        song('1'),
                        song('2'),
                        song('3'),
                      ]),
                  child: const Text('打开'),
                ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('将 3 首加入歌单'), findsOneWidget);

      await tester.tap(find.text('批量'));
      await tester.pumpAndSettle();

      expect(repository.addedTracks['批量'], hasLength(3));
      expect(find.textContaining('已将 3 首加入'), findsOneWidget);
    });

    testWidgets('空曲目列表不弹出面板', (tester) async {
      await tester.pumpWidget(
        host(
          Builder(
            builder:
                (context) => TextButton(
                  onPressed: () => AddToPlaylistSheet.show(context, const []),
                  child: const Text('打开'),
                ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('新建歌单'), findsNothing);
    });

    testWidgets('仓库写入失败时给出失败提示，不静默', (tester) async {
      repository
        ..seedPlaylist('会失败', const [])
        ..failOnAdd = true;

      await tester.pumpWidget(
        host(
          Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => AddToPlaylistSheet.show(context, [song('1')]),
                  child: const Text('打开'),
                ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('会失败'));
      await tester.pumpAndSettle();

      expect(find.textContaining('加入失败'), findsOneWidget);
    });
  });

  group('TrackTile 操作菜单接线（D2）', () {
    testWidgets('菜单包含加入歌单 / 下一首播放 / 添加到队列', (tester) async {
      await tester.pumpWidget(
        host(TrackTile(track: song('1'), queue: [song('1')])),
      );

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();

      expect(find.text('加入歌单'), findsOneWidget);
      expect(find.text('下一首播放'), findsOneWidget);
      expect(find.text('添加到队列末尾'), findsOneWidget);
    });

    testWidgets('从菜单进入加入歌单面板', (tester) async {
      await tester.pumpWidget(
        host(TrackTile(track: song('1'), queue: [song('1')])),
      );

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入歌单'));
      await tester.pumpAndSettle();

      // 面板已打开（无歌单时显示引导）
      expect(find.text('还没有歌单，先新建一个吧'), findsOneWidget);
    });

    testWidgets('收藏按钮切换收藏状态', (tester) async {
      final track = song('5');
      await tester.pumpWidget(host(TrackTile(track: track, queue: [track])));

      await tester.tap(find.byTooltip('喜欢'));
      await tester.pumpAndSettle();

      expect(repository.favoriteToggles, contains('netease:5'));
    });
  });
}

/// 内存假仓库：只记录调用，不做任何 IO。
///
/// 只实现 UI 会用到的方法，其余抛错——一旦界面新增了对仓库的调用，
/// 测试会立刻暴露，而不是被静默忽略。
class _FakeLibraryRepository implements LibraryRepository {
  final Map<String, List<Track>> _playlists = <String, List<Track>>{};
  final List<String> addedTo = <String>[];
  final Map<String, List<Track>> addedTracks = <String, List<Track>>{};
  final List<String> favoriteToggles = <String>[];
  final Set<String> _favorites = <String>{};

  bool failOnAdd = false;

  void seedPlaylist(String name, List<Track> tracks) {
    _playlists[name] = List<Track>.of(tracks);
  }

  @override
  List<String> get playlistNames => _playlists.keys.toList()..sort();

  @override
  List<Track> playlistTracks(String name) =>
      List<Track>.of(_playlists[name] ?? const <Track>[]);

  @override
  Future<void> createPlaylist(String name) async {
    _playlists.putIfAbsent(name, () => <Track>[]);
  }

  @override
  Future<void> addManyToPlaylist(String name, Iterable<Track> tracks) async {
    if (failOnAdd) throw StateError('模拟写入失败');
    addedTo.add(name);
    addedTracks[name] = List<Track>.of(tracks);
    _playlists.putIfAbsent(name, () => <Track>[]);
  }

  @override
  bool isFavorite(String trackKey) => _favorites.contains(trackKey);

  @override
  Future<bool> toggleFavorite(Track track) async {
    favoriteToggles.add(track.key);
    if (!_favorites.remove(track.key)) {
      _favorites.add(track.key);
      return true;
    }
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('假仓库未实现：${invocation.memberName}');
}

/// 桩播放器：单元测试环境没有 just_audio 原生实现。
class _StubPlayer extends Mock implements ja.AudioPlayer {
  @override
  Stream<ja.PlayerState> get playerStateStream =>
      const Stream<ja.PlayerState>.empty();

  @override
  Stream<ja.PlaybackEvent> get playbackEventStream =>
      const Stream<ja.PlaybackEvent>.empty();

  @override
  ja.PlaybackEvent get playbackEvent =>
      ja.PlaybackEvent(processingState: ja.ProcessingState.idle);

  @override
  bool get playing => false;

  @override
  ja.ProcessingState get processingState => ja.ProcessingState.idle;

  @override
  Duration get position => Duration.zero;

  @override
  Duration get bufferedPosition => Duration.zero;

  @override
  double get speed => 1.0;

  @override
  Future<void> dispose() async {}
}
