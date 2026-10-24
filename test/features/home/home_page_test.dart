import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/auth/auth_capability.dart';
import 'package:musaic/core/auth/source_account.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/core/model/remote_playlist.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/capabilities.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/features/auth/application/account_notifier.dart';
import 'package:musaic/features/home/home_page.dart';
import 'package:musaic/features/library/data/library_repository.dart';
import 'package:musaic/features/player/data/resume_repository.dart';
import 'package:musaic/features/player/player_notifier.dart';

/// 首页丰富化（日常可用性计划 D6）。
///
/// 重点钉住两条容易回退的契约：
/// 1. **无断点快照时不显示「继续收听」卡**——不留空占位。
///    这是「打开应用第一眼看到的是内容而不是空壳」的底线；
/// 2. 登录渠道的账号歌单出现在首页「我的歌单」，未登录时给出登录入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box<String> favoritesBox;
  late Box<String> historyBox;
  late Box<String> playlistsBox;
  late Box<String> resumeBox;
  late LibraryRepository library;
  late ResumeRepository resume;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_home_test');
    Hive.init(tempDir.path);
    favoritesBox = await Hive.openBox<String>('home_favorites');
    historyBox = await Hive.openBox<String>('home_history');
    playlistsBox = await Hive.openBox<String>('home_playlists');
    resumeBox = await Hive.openBox<String>('home_resume');
  });

  tearDownAll(() async {
    await favoritesBox.close();
    await historyBox.close();
    await playlistsBox.close();
    await resumeBox.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  setUp(() async {
    await favoritesBox.clear();
    await historyBox.clear();
    await playlistsBox.clear();
    await resumeBox.clear();
    library = LibraryRepository(
      favoritesBox: favoritesBox,
      historyBox: historyBox,
      playlistsBox: playlistsBox,
    );
    resume = ResumeRepository(box: resumeBox);
  });

  Track song(String id, {String artist = 'Beyond'}) =>
      Track(id: id, sourceId: 'netease', title: '海阔天空$id', artist: artist);

  /// 在 `testWidgets` 的 fake-async 区里执行**真实 Hive IO**。
  ///
  /// 这是本文件最容易踩的坑：`testWidgets` 默认把异步任务放在伪造时钟里，
  /// 而 Hive 的磁盘写入依赖真实事件循环，`await box.put(...)` 会永远挂起
  /// （表现为测试「跑完但不结束」，最后被测试框架超时杀掉）。
  /// 因此所有直接落盘的操作都必须经 [WidgetTester.runAsync] 执行。
  Future<T> realIo<T>(WidgetTester tester, Future<T> Function() action) async {
    final result = await tester.runAsync(action);
    return result as T;
  }

  Future<void> pumpHome(
    WidgetTester tester, {
    List<MusicSource> sources = const [],
    AccountNotifier Function()? accounts,
  }) async {
    final registry = SourceRegistry();
    for (final source in sources) {
      registry.register(source);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(library),
          resumeRepositoryProvider.overrideWithValue(resume),
          // 首页不直接查渠道，但快捷入口/空态依赖注册表存在
          sourceRegistryProvider.overrideWithValue(registry),
          if (accounts != null) accountsProvider.overrideWith(accounts),
          // 播放器桩：不触碰 audioHandler，避免测试环境初始化音频栈
          playerNotifierProvider.overrideWith(_StubPlayerNotifier.new),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('无断点快照时不显示「继续收听」卡（不留空占位）', (tester) async {
    await pumpHome(tester);

    expect(find.text('继续收听'), findsNothing, reason: '没有快照就不该出现这张卡，而不是渲染一张空卡');
    expect(find.text('继续播放'), findsNothing);

    // 无历史时应落到「扫描本地音乐」引导，说明首页仍然可用
    expect(find.text('扫描本地音乐'), findsOneWidget);
    // 搜索才是新用户的第一步：空态必须给出直达入口
    expect(find.text('去搜索'), findsOneWidget);
  });

  testWidgets('有断点快照时显示继续收听卡与「继续播放」按钮', (tester) async {
    await realIo(
      tester,
      () => resume.save(
        ResumePlayback(
          queue: [song('1'), song('2')],
          index: 1,
          position: const Duration(seconds: 30),
          savedAt: DateTime.now(),
        ),
      ),
    );

    await pumpHome(tester);

    expect(find.text('继续收听'), findsOneWidget);
    expect(find.text('继续播放'), findsOneWidget);
    // 快照里的当前曲目（index = 1）
    expect(find.text('海阔天空2'), findsOneWidget);
    expect(find.textContaining('Beyond'), findsWidgets);
  });

  testWidgets('「我喜欢的音乐」显示收藏数量，本地歌单出现在「我的歌单」', (tester) async {
    await realIo(
      tester,
      () => favoritesBox.put(
        song('f1').key,
        '{"id":"f1","sourceId":"netease","title":"t","artist":"a"}',
      ),
    );
    await realIo(tester, () => library.createPlaylist('通勤'));

    await pumpHome(tester);

    expect(find.text('我喜欢的音乐'), findsOneWidget);
    expect(find.text('1 首'), findsOneWidget);
    expect(find.byTooltip('播放全部喜欢'), findsOneWidget);
    expect(find.text('我的歌单'), findsOneWidget);
    expect(find.text('通勤'), findsOneWidget);
  });

  group('账号歌单上首页（真机反馈：登录后看不到歌单）', () {
    testWidgets('已登录：账号歌单出现在「我的歌单」并标注渠道', (tester) async {
      await pumpHome(
        tester,
        sources: [_PlaylistSource(personal: true)],
        accounts: _LoggedInAccounts.new,
      );

      expect(find.text('我的歌单'), findsOneWidget);
      expect(find.text('我喜欢的音乐(网易云)'), findsOneWidget);
      expect(find.text('假渠道'), findsOneWidget, reason: '多渠道混排时需看出来源');
      expect(find.text('同步账号歌单'), findsNothing);
    });

    testWidgets('未登录：给出「同步账号歌单」入口而不是什么都不显示', (tester) async {
      await pumpHome(
        tester,
        sources: [_PlaylistSource(personal: true)],
        accounts: _LoggedOutAccounts.new,
      );

      expect(find.text('同步账号歌单'), findsOneWidget);
    });

    testWidgets('推荐歌单（非本人）不混进「我的歌单」', (tester) async {
      await pumpHome(
        tester,
        sources: [_PlaylistSource(personal: false)],
        accounts: _LoggedInAccounts.new,
      );

      expect(find.text('我喜欢的音乐(网易云)'), findsNothing);
      expect(find.text('我的歌单'), findsNothing);
    });
  });
}

class _PlaylistSource extends MusicSource implements RemotePlaylistCapable {
  _PlaylistSource({required this.personal})
    : super(credentialReader: () async => const <String, String>{});

  final bool personal;

  @override
  bool get remotePlaylistsArePersonal => personal;

  @override
  String get sourceId => 'fake';

  @override
  String get displayName => '假渠道';

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
  Future<ResolvedStream> resolveStream(Track track) async =>
      const ResolvedStream(url: '');

  @override
  Future<LyricBundle?> fetchLyrics(Track track) async => null;

  @override
  Future<List<RemotePlaylist>> fetchRemotePlaylists(String userId) async =>
      const [
        RemotePlaylist(
          sourceId: 'fake',
          id: '1',
          name: '我喜欢的音乐(网易云)',
          trackCount: 12,
        ),
      ];

  @override
  Future<List<Track>> fetchRemotePlaylistTracks(String playlistId) async =>
      const <Track>[];
}

class _LoggedInAccounts extends AccountNotifier {
  @override
  AccountsState build() => AccountsState(
    bySource: <String, SourceAccount>{
      'fake': SourceAccount.markNow(
        sourceId: 'fake',
        status: AccountStatus.loggedIn,
        userId: '1',
      ),
    },
  );
}

class _LoggedOutAccounts extends AccountNotifier {
  @override
  AccountsState build() => const AccountsState();
}

/// 跳过 audioHandler 初始化的播放器状态（与其他 Widget 测试同款桩）。
class _StubPlayerNotifier extends PlayerNotifier {
  @override
  PlayerState build() => const PlayerState();
}
