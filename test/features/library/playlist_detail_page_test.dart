import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/theme/app_tokens.dart';
import 'package:musaic/features/library/data/library_repository.dart';
import 'package:musaic/features/library/playlist_detail_page.dart';
import 'package:musaic/features/player/audio_handler.dart';
import 'package:musaic/features/player/data/resume_repository.dart';
import 'package:musaic/features/settings/settings_providers.dart';

/// 歌单详情页 **响应式刷新** 的接线测试（U2 回归）。
///
/// ## 被固化的缺陷
///
/// 本页原先只 `ref.watch(libraryRepositoryProvider)`——一个普通 `Provider`，
/// 永不变化；曲目内容直接取自 `repository.playlistTracks(name)` 的**一次性**读取。
/// 于是当别处（搜索页加入、批量加入、备份导入）改动歌单后，
/// 停留在本页的用户看到的是**过期列表**，必须退出重进才能看到新内容。
///
/// 修复引入 `playlistTracksProvider`（autoDispose family，跟随
/// `repository.watchPlaylists()`）。本测试用**可控的 Box 事件流**驱动它：
/// 推送一次事件后，界面必须自行出现新曲目——不需要任何重建或重进。
///
/// 分层：仓库为内存假实现（不碰 Hive），只验证接线与刷新路径；
/// 真实落盘语义由 `library_repository_test.dart` / `main_flow_test.dart` 覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLibraryRepository repository;
  late Directory tempDir;
  late Box<String> resumeBox;
  late Box<String> settingsBox;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_playlist_detail');
    Hive.init(tempDir.path);
    resumeBox = await Hive.openBox<String>('pd_resume');
    settingsBox = await Hive.openBox<String>('pd_settings');
  });

  tearDownAll(() async {
    if (resumeBox.isOpen) await resumeBox.close();
    if (settingsBox.isOpen) await settingsBox.close();
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

  Track song(String id) =>
      Track(id: id, sourceId: 'netease', title: '歌$id', artist: 'Beyond');

  Widget host() {
    return ProviderScope(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repository),
        sourceRegistryProvider.overrideWithValue(SourceRegistry()),
        audioHandlerProvider.overrideWithValue(
          MusaicAudioHandler(player: _StubPlayer()),
        ),
        resumeRepositoryProvider.overrideWithValue(
          ResumeRepository(box: resumeBox),
        ),
        appSettingsRepositoryProvider.overrideWithValue(
          AppSettingsRepository(box: settingsBox),
        ),
      ],
      child: MaterialApp(
        theme: AppTokens.darkTheme,
        home: const PlaylistDetailPage(name: '通勤'),
      ),
    );
  }

  testWidgets('别处写入歌单后，本页自动出现新曲目（无需重进）', (tester) async {
    repository.seedPlaylist('通勤', [song('a')]);

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('歌a'), findsOneWidget);
    expect(find.text('歌b'), findsNothing);

    // 模拟「在别处把 b 加进同一歌单」：数据源变了，并推送一次 Box 事件。
    repository.seedPlaylist('通勤', [song('a'), song('b')]);
    repository.emitPlaylistsChanged();
    await tester.pumpAndSettle();

    // 核心断言：不重进、不重建，界面自行刷新出新内容
    expect(
      find.text('歌b'),
      findsOneWidget,
      reason: '歌单内容变更必须响应式反映到详情页（U2 状态同步缺陷）',
    );
  });

  testWidgets('移除单曲后列表就地更新', (tester) async {
    repository.seedPlaylist('通勤', [song('a'), song('b')]);

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('歌a'), findsOneWidget);

    // 移除按钮是 trailing 的 remove_circle_outline 图标（无 tooltip）。
    await tester.tap(find.byIcon(Icons.remove_circle_outline_rounded).first);
    await tester.pumpAndSettle();

    // 计划 4.2：移除按 key 定位，而不是按下标。
    expect(repository.removedKeys, [song('a').key]);
    expect(find.text('歌a'), findsNothing);
    expect(find.text('歌b'), findsOneWidget);
  });

  testWidgets('4.2 列表在渲染后重排，移除的仍是用户点的那一首', (tester) async {
    // 复现原缺陷：点「第一行」的移除按钮时，若列表已被重排，
    // 下标 0 已指向另一首歌 —— 按下标删除会删错。
    // 这里在点击前把顺序倒过来，模拟别处写入/响应式刷新导致的重排。
    repository.seedPlaylist('通勤', [song('a'), song('b'), song('c')]);

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('歌a'), findsOneWidget);

    // 渲染完成后重排：a 从第 0 位挪到第 2 位
    repository.seedPlaylist('通勤', [song('b'), song('c'), song('a')]);
    repository.emitPlaylistsChanged();
    await tester.pumpAndSettle();

    // 现在第一行是「歌b」，点它的移除按钮
    await tester.tap(find.byIcon(Icons.remove_circle_outline_rounded).first);
    await tester.pumpAndSettle();

    // 必须是「歌b」被删；按下标实现会删掉当时下标 0 指向的歌，
    // 若实现退化为「用渲染时捕获的下标」则可能删错。
    expect(repository.removedKeys, [
      song('b').key,
    ], reason: '移除必须按内容标识定位，重排后仍要删中用户点的那一首');
    expect(find.text('歌b'), findsNothing);
    expect(find.text('歌a'), findsOneWidget);
    expect(find.text('歌c'), findsOneWidget);
  });

  testWidgets('空歌单显示明确空状态且无「播放全部」', (tester) async {
    repository.seedPlaylist('通勤', const []);

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.textContaining('歌单还是空的'), findsOneWidget);
    expect(find.text('播放全部'), findsNothing);
  });

  // ---------------------------------------------------------------------
  // 计划 2.3 验收：重命名对话框的 TextEditingController 生命周期。
  //
  // 旧实现由**调用方**创建 controller，`await showDialog` 返回后立刻
  // `dispose()`；而对话框退场动画期间 TextField 仍然存活并继续读 controller，
  // 于是抛 `A TextEditingController was used after being disposed`。
  //
  // 保存与取消两条路径各跑 10 次：任何一次抛异常都会让本用例失败。
  // 注意 `_rename` 里会调用 `GoRouter.of(context)` 并在成功后
  // `pushReplacement`，所以这里必须用真实路由而不是 `MaterialApp(home:)`。
  // ---------------------------------------------------------------------

  GoRouter renameRouter(String initialName) => GoRouter(
    initialLocation: '/playlist/${Uri.encodeComponent(initialName)}',
    routes: [
      GoRoute(
        path: '/playlist/:name',
        builder:
            (context, state) =>
                PlaylistDetailPage(name: state.pathParameters['name']!),
      ),
    ],
  );

  Widget renameHost(GoRouter router) {
    return ProviderScope(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repository),
        sourceRegistryProvider.overrideWithValue(SourceRegistry()),
        audioHandlerProvider.overrideWithValue(
          MusaicAudioHandler(player: _StubPlayer()),
        ),
        resumeRepositoryProvider.overrideWithValue(
          ResumeRepository(box: resumeBox),
        ),
        appSettingsRepositoryProvider.overrideWithValue(
          AppSettingsRepository(box: settingsBox),
        ),
      ],
      child: MaterialApp.router(
        theme: AppTokens.darkTheme,
        routerConfig: router,
      ),
    );
  }

  Future<void> openRenameDialog(WidgetTester tester) async {
    await tester.tap(find.byTooltip('重命名'));
    await tester.pumpAndSettle();
    expect(find.text('重命名歌单'), findsOneWidget);
  }

  testWidgets('重命名保存 10 次：不抛 controller 已销毁异常，名称与内容正确', (tester) async {
    repository.seedPlaylist('歌单0', [song('a')]);
    await tester.pumpWidget(renameHost(renameRouter('歌单0')));
    await tester.pumpAndSettle();

    for (var i = 0; i < 10; i++) {
      final next = '歌单${i + 1}';
      await openRenameDialog(tester);
      await tester.enterText(find.byType(TextField), next);
      await tester.tap(find.text('保存'));
      // pumpAndSettle 会走完对话框退场动画——旧实现正是在此期间抛异常。
      await tester.pumpAndSettle();

      expect(find.text(next), findsWidgets, reason: '标题应显示新名称（第 ${i + 1} 次）');
      expect(
        find.text('歌a'),
        findsOneWidget,
        reason: '改名后曲目内容不得丢失（第 ${i + 1} 次改名后出现空歌单）',
      );
    }

    expect(repository.renamedTo, hasLength(10));
  });

  testWidgets('重命名取消 10 次：不抛 controller 已销毁异常，名称不变', (tester) async {
    repository.seedPlaylist('歌单0', [song('a')]);
    await tester.pumpWidget(renameHost(renameRouter('歌单0')));
    await tester.pumpAndSettle();

    for (var i = 0; i < 10; i++) {
      await openRenameDialog(tester);
      await tester.enterText(find.byType(TextField), '不应生效$i');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(
        repository.renamedTo,
        isEmpty,
        reason: '取消不得触发任何重命名（第 ${i + 1} 次）',
      );
      expect(find.text('歌单0'), findsWidgets, reason: '取消后名称必须保持不变');
      expect(find.text('歌a'), findsOneWidget);
    }
  });
}

/// 内存假仓库：可手动推送歌单变更事件，用来验证响应式刷新。
class _FakeLibraryRepository implements LibraryRepository {
  final Map<String, List<Track>> _playlists = <String, List<Track>>{};
  final _playlistEvents = StreamController<BoxEvent>.broadcast();

  final List<int> removedIndexes = <int>[];

  /// 计划 4.2：按 key 移除的记录（详情页现在走这条路径）。
  final List<String> removedKeys = <String>[];

  /// 记录每次成功的重命名（旧名 → 新名），供 2.3 的取消/保存断言使用。
  final List<String> renamedTo = <String>[];

  void seedPlaylist(String name, List<Track> tracks) {
    _playlists[name] = List<Track>.of(tracks);
  }

  void emitPlaylistsChanged() {
    // 事件内容不被消费（Provider 按名重读），只需触发一次。
    _playlistEvents.add(BoxEvent('通勤', null, false));
  }

  @override
  List<String> get playlistNames => _playlists.keys.toList();

  @override
  List<Track> playlistTracks(String name) =>
      List<Track>.of(_playlists[name] ?? const <Track>[]);

  @override
  Stream<BoxEvent> watchPlaylists() => _playlistEvents.stream;

  @override
  Future<void> removeFromPlaylist(String rawName, int index) async {
    removedIndexes.add(index);
    final tracks = _playlists[rawName];
    if (tracks == null || index < 0 || index >= tracks.length) return;
    tracks.removeAt(index);
    // 真实仓库经 _writePlaylist → Box.put 触发 Box 事件；此处等价模拟，
    // 否则界面没有刷新信号，测试会假失败。
    emitPlaylistsChanged();
  }

  /// 计划 4.2：详情页改为按 key 移除，假仓库同步记录被删的 key。
  @override
  Future<bool> removeFromPlaylistByKey(String rawName, String trackKey) async {
    removedKeys.add(trackKey);
    final tracks = _playlists[rawName];
    if (tracks == null) return false;
    final before = tracks.length;
    tracks.removeWhere((t) => t.key == trackKey);
    if (tracks.length == before) return false;
    emitPlaylistsChanged();
    return true;
  }

  @override
  bool isFavorite(String trackKey) => false;

  @override
  Future<bool> renamePlaylist(String rawOldName, String rawNewName) async {
    final tracks = _playlists[rawOldName];
    if (tracks == null) return false;
    if (_playlists.containsKey(rawNewName)) return false;
    _playlists[rawNewName] = tracks;
    _playlists.remove(rawOldName);
    renamedTo.add(rawNewName);
    emitPlaylistsChanged();
    return true;
  }

  @override
  Stream<BoxEvent> watchFavorites() => const Stream<BoxEvent>.empty();

  @override
  Stream<BoxEvent> watchHistory() => const Stream<BoxEvent>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('假仓库未实现：${invocation.memberName}');
}

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
  double get volume => 1.0;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> dispose() async {}
}
