import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/auth/auth_capability.dart';
import 'package:musaic/core/auth/source_account.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/error/source_exception.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/core/model/remote_playlist.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/capabilities.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/features/auth/application/account_notifier.dart';
import 'package:musaic/features/library/data/library_repository.dart';
import 'package:musaic/features/library/data/remote_playlists_provider.dart';
import 'package:musaic/features/library/library_page.dart';

/// 账号歌单三态与重试（改进计划 B6）。
///
/// 原实现把渠道异常吞成空列表（`playlistsAsync.value ?? []`），弱网下
/// 用户看到的是「没有歌单」而不是「加载失败」，也没有任何重取入口。
/// 本测试把「失败必须可见且可重试」固化为契约，含 UI 层断言——
/// 只测 Provider 的话，旧代码同样能通过（它确实会 error，是 UI 吃掉了）。
class _FakeSource extends MusicSource implements RemotePlaylistCapable {
  _FakeSource({this.failList = false, this.failTracks = false})
    : super(credentialReader: () async => const <String, String>{});

  /// 可变：模拟「用户点重试时网络已恢复」。
  bool failList;
  bool failTracks;

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
  Future<List<RemotePlaylist>> fetchRemotePlaylists(String userId) async {
    if (failList) {
      throw NetworkSourceException('歌单加载失败：网络异常', sourceId: sourceId);
    }
    return const <RemotePlaylist>[];
  }

  @override
  Future<List<Track>> fetchRemotePlaylistTracks(String playlistId) async {
    if (failTracks) {
      throw NetworkSourceException('详情加载失败：网络异常', sourceId: sourceId);
    }
    return const <Track>[];
  }
}

/// 直接给已登录账号，绕开 AccountNotifier 的 Hive 依赖。
class _LoggedInAccounts extends AccountNotifier {
  @override
  AccountsState build() => AccountsState(
    bySource: <String, SourceAccount>{
      'fake': SourceAccount.markNow(
        sourceId: 'fake',
        status: AccountStatus.loggedIn,
        userId: '12345',
      ),
    },
  );
}

/// 未登录账号（同样绕开 Hive）。
class _LoggedOutAccounts extends AccountNotifier {
  @override
  AccountsState build() => const AccountsState();
}

ProviderContainer _container(_FakeSource source) {
  final registry = SourceRegistry()..register(source);
  final container = ProviderContainer(
    overrides: [
      sourceRegistryProvider.overrideWithValue(registry),
      accountsProvider.overrideWith(_LoggedInAccounts.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('B6：账号歌单三态', () {
    test('失败保留为 AsyncError，不再被吞成空态', () async {
      final container = _container(_FakeSource(failList: true));
      await expectLater(
        container.read(remotePlaylistsProvider('fake').future),
        throwsA(isA<NetworkSourceException>()),
      );
      final state = container.read(remotePlaylistsProvider('fake'));
      expect(state.hasError, isTrue);
      // 渠道异常取领域文案，不透出底层堆栈 / URL
      expect(remotePlaylistsErrorMessage(state.error!), '歌单加载失败：网络异常');
    });

    test('invalidate 后可重试成功（错误态 → 成功态）', () async {
      final container = _container(_FakeSource(failList: true));
      await container
          .read(remotePlaylistsProvider('fake').future)
          .then((_) {}, onError: (_) {});
      expect(container.read(remotePlaylistsProvider('fake')).hasError, isTrue);

      // 渠道恢复后 invalidate，等价于用户点「重试」
      final source = container.read(sourceRegistryProvider).resolve('fake')!;
      (source as _FakeSource).failList = false;
      container.invalidate(remotePlaylistsProvider('fake'));

      await container.read(remotePlaylistsProvider('fake').future);
      final state = container.read(remotePlaylistsProvider('fake'));
      expect(state.hasError, isFalse);
      expect(state.value, isEmpty);
    });

    test('未登录是空态而非错误态，且分区不渲染', () async {
      final registry = SourceRegistry()..register(_FakeSource(failList: true));
      final container = ProviderContainer(
        overrides: [
          sourceRegistryProvider.overrideWithValue(registry),
          accountsProvider.overrideWith(_LoggedOutAccounts.new),
        ],
      );
      addTearDown(container.dispose);

      await container.read(remotePlaylistsProvider('fake').future);
      final state = container.read(remotePlaylistsProvider('fake'));
      expect(state.hasError, isFalse);
      expect(state.value, isEmpty);
      // 未登录 → 能力不可用 → 消费方据此隐藏整节（含加载骨架）
      expect(container.read(remotePlaylistCapableProvider('fake')), isNull);
    });

    test('详情失败同样保留为 AsyncError', () async {
      const playlist = RemotePlaylist(
        sourceId: 'fake',
        id: '1',
        name: '测试歌单',
        trackCount: 0,
      );
      final container = _container(_FakeSource(failTracks: true));
      await expectLater(
        container.read(remotePlaylistTracksProvider(playlist).future),
        throwsA(isA<NetworkSourceException>()),
      );
      expect(
        remotePlaylistsErrorMessage(
          container.read(remotePlaylistTracksProvider(playlist)).error!,
        ),
        '详情加载失败：网络异常',
      );
    });
  });

  group('B6 UI：账号歌单失败态可重试', () {
    late Directory tempDir;
    late LibraryRepository repository;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('musaic_b6_ui');
      Hive.init(tempDir.path);
    });

    tearDownAll(() async {
      await tempDir.delete(recursive: true);
    });

    setUp(() async {
      repository = LibraryRepository(
        favoritesBox: await Hive.openBox<String>('b6_favorites'),
        historyBox: await Hive.openBox<String>('b6_history'),
        playlistsBox: await Hive.openBox<String>('b6_playlists'),
      );
    });

    testWidgets('失败渲染错误与「重试」；点击后重新拉取并恢复', (tester) async {
      final source = _FakeSource(failList: true);
      final registry = SourceRegistry()..register(source);
      final container = ProviderContainer(
        overrides: [
          sourceRegistryProvider.overrideWithValue(registry),
          accountsProvider.overrideWith(_LoggedInAccounts.new),
          libraryRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LibraryPage()),
        ),
      );
      await tester.tap(find.text('歌单'));
      await tester.pumpAndSettle();

      // 旧实现（value ?? []）此处什么都没有：错误被静默成空态
      expect(find.textContaining('歌单加载失败：网络异常'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '重试'), findsOneWidget);

      // 网络恢复后点「重试」→ ref.invalidate 重新拉取
      source.failList = false;
      await tester.tap(find.widgetWithText(TextButton, '重试'));
      await tester.pumpAndSettle();

      expect(find.textContaining('歌单加载失败'), findsNothing);
      expect(find.widgetWithText(TextButton, '重试'), findsNothing);
    });
  });
}
