import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musaic/core/auth/auth_capability.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/capabilities.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/theme/app_tokens.dart';
import 'package:musaic/features/settings/data/local_music_settings_repository.dart';
import 'package:musaic/features/settings/local_music_settings_page.dart';

/// 本地音乐设置页交互测试（覆盖率门槛补齐：此前该文件 0.7% 覆盖）。
///
/// ## 为什么用内存假仓库
///
/// `testWidgets` 的假时钟下真实 Hive 写入**永不完成**——测试既不失败也不
/// 结束，最后被框架超时杀掉且没有断言信息（本项目已多次踩坑）。
/// 因此这里把 [LocalMusicSettingsRepository] 子类化为纯内存实现：
/// 页面调用的每个读写方法都被覆盖，`box` 仅用于满足构造函数，永不触碰。
///
/// `_ensurePermission()` 在非 Android 平台直接返回 true，所以宿主（macOS）
/// 上不会触发 permission_handler 平台通道；「未授予权限」分支因此不可达，
/// 这里不强行覆盖。
class _MockBox extends Mock implements Box<String> {}

/// 纯内存的本地音乐设置仓库。
class _FakeRepo extends LocalMusicSettingsRepository {
  _FakeRepo({List<String> folders = const <String>[], bool autoScan = false})
    : _folders = List<String>.of(folders),
      _autoScan = autoScan,
      super(box: _MockBox());

  final List<String> _folders;
  bool _autoScan;

  final List<String> addCalls = <String>[];
  final List<String> removeCalls = <String>[];
  final List<bool> autoScanWrites = <bool>[];

  @override
  List<String> get folders => List<String>.unmodifiable(_folders);

  @override
  Future<void> addFolder(String path) async {
    addCalls.add(path);
    if (!_folders.contains(path)) _folders.add(path);
  }

  @override
  Future<void> removeFolder(String path) async {
    removeCalls.add(path);
    _folders.remove(path);
  }

  @override
  bool get autoScanOnStartup => _autoScan;

  @override
  Future<void> setAutoScanOnStartup(bool value) async {
    autoScanWrites.add(value);
    _autoScan = value;
  }
}

/// 具备扫描能力的假渠道。
class _FakeScanSource extends MusicSource implements LibraryScanCapable {
  _FakeScanSource({this.result = const <Track>[], this.error, this.gate})
    : super(credentialReader: () async => const <String, String>{});

  final List<Track> result;
  final Object? error;

  /// 非空时 `scanLibrary` 会挂起，直到测试完成它（用于观察「正在扫描…」）。
  final Completer<void>? gate;

  int scanCalls = 0;
  int invalidateCalls = 0;

  @override
  String get sourceId => 'fake-local';

  @override
  String get displayName => '假本地渠道';

  @override
  AuthCapability get authCapability => AuthCapability.noAuth;

  @override
  Future<List<Track>> scanLibrary({bool force = false}) async {
    scanCalls++;
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return result;
  }

  @override
  void invalidateScanCache() => invalidateCalls++;

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
}

/// 不具备扫描能力的渠道（用于验证「找不到扫描源」时不崩溃）。
class _PlainSource extends MusicSource {
  _PlainSource()
    : super(credentialReader: () async => const <String, String>{});

  @override
  String get sourceId => 'plain';

  @override
  String get displayName => '无扫描能力渠道';

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
}

Track song(String id) => Track(
  id: id,
  sourceId: 'fake-local',
  title: '曲$id',
  artist: '歌手',
  duration: const Duration(seconds: 30),
);

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required _FakeRepo repo,
    MusicSource? source,
  }) async {
    final registry = SourceRegistry();
    if (source != null) registry.register(source);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localMusicSettingsRepositoryProvider.overrideWithValue(repo),
          sourceRegistryProvider.overrideWithValue(registry),
        ],
        child: MaterialApp(
          theme: AppTokens.darkTheme,
          home: const LocalMusicSettingsPage(),
        ),
      ),
    );
    await tester.pump();
  }

  /// SnackBar 断言：tap → pump() → pump(300ms)（不要用 pumpAndSettle）。
  Future<void> settleSnackBar(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('文件夹列表与空态', () {
    testWidgets('空文件夹：显示引导文案，计数为 0', (tester) async {
      final repo = _FakeRepo();
      await pumpPage(tester, repo: repo);

      expect(find.text('扫描文件夹（0）'), findsOneWidget);
      expect(find.text('尚未添加文件夹'), findsOneWidget);
      expect(find.text('添加音乐文件夹后点击「立即扫描」建立本地曲库'), findsOneWidget);
    });

    testWidgets('已添加文件夹：渲染路径与移除按钮，计数正确', (tester) async {
      final repo = _FakeRepo(folders: ['/music/a', '/music/b']);
      await pumpPage(tester, repo: repo);

      expect(find.text('扫描文件夹（2）'), findsOneWidget);
      expect(find.text('/music/a'), findsOneWidget);
      expect(find.text('/music/b'), findsOneWidget);
      expect(find.text('尚未添加文件夹'), findsNothing);
      expect(find.byTooltip('移除'), findsNWidgets(2));
    });
  });

  group('移除文件夹（破坏性操作需确认）', () {
    testWidgets('取消确认：不移除，文件夹仍在', (tester) async {
      final repo = _FakeRepo(folders: ['/music/a']);
      await pumpPage(tester, repo: repo);

      await tester.tap(find.byTooltip('移除'));
      await tester.pumpAndSettle();

      expect(find.text('移除该文件夹？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(repo.removeCalls, isEmpty);
      expect(find.text('/music/a'), findsOneWidget);
    });

    testWidgets('确认后：调用 removeFolder 并从列表移除', (tester) async {
      final repo = _FakeRepo(folders: ['/music/a']);
      await pumpPage(tester, repo: repo);

      await tester.tap(find.byTooltip('移除'));
      await tester.pumpAndSettle();

      // 对话框确认按钮文案为「移除」；文件夹行的移除控件是 tooltip 不是 Text，
      // 因此此处 find.text('移除') 唯一命中对话框按钮。
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();

      expect(repo.removeCalls, ['/music/a']);
      expect(find.text('/music/a'), findsNothing);
      expect(find.text('尚未添加文件夹'), findsOneWidget);
    });
  });

  group('启动时自动扫描开关', () {
    testWidgets('开关初值来自仓库', (tester) async {
      await pumpPage(tester, repo: _FakeRepo(autoScan: true));

      final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(sw.value, isTrue);
    });

    testWidgets('切换开关写入仓库并更新界面', (tester) async {
      final repo = _FakeRepo(autoScan: false);
      await pumpPage(tester, repo: repo);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(repo.autoScanWrites, [true]);
      final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(sw.value, isTrue);
    });
  });

  group('立即扫描', () {
    testWidgets('成功：提示数量并显示上次扫描结果', (tester) async {
      final source = _FakeScanSource(result: [song('1'), song('2')]);
      await pumpPage(tester, repo: _FakeRepo(), source: source);

      await tester.tap(find.text('立即扫描'));
      await settleSnackBar(tester);

      expect(source.invalidateCalls, 1, reason: '扫描前必须失效缓存');
      expect(source.scanCalls, 1);
      expect(find.text('扫描完成，找到 2 首歌曲'), findsOneWidget);
      expect(find.text('上次扫描：2 首'), findsOneWidget);
    });

    testWidgets('失败：给出可读提示，不崩溃', (tester) async {
      final source = _FakeScanSource(error: Exception('boom'));
      await pumpPage(tester, repo: _FakeRepo(), source: source);

      await tester.tap(find.text('立即扫描'));
      await settleSnackBar(tester);

      expect(find.text('扫描失败，请检查目录与存储权限'), findsOneWidget);
      expect(find.text('上次扫描：0 首'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('扫描中：按钮禁用并显示「正在扫描…」', (tester) async {
      final gate = Completer<void>();
      final source = _FakeScanSource(result: [song('1')], gate: gate);
      await pumpPage(tester, repo: _FakeRepo(), source: source);

      await tester.tap(find.text('立即扫描'));
      await tester.pump();

      expect(find.text('正在扫描…'), findsOneWidget);
      expect(find.text('立即扫描'), findsNothing);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull, reason: '扫描中必须禁用，避免重复触发');

      gate.complete();
      await settleSnackBar(tester);

      expect(find.text('立即扫描'), findsOneWidget);
      expect(find.text('扫描完成，找到 1 首歌曲'), findsOneWidget);
    });

    testWidgets('渠道不支持扫描时：静默返回，不崩溃也不提示', (tester) async {
      await pumpPage(tester, repo: _FakeRepo(), source: _PlainSource());

      await tester.tap(find.text('立即扫描'));
      await settleSnackBar(tester);

      expect(find.textContaining('扫描完成'), findsNothing);
      expect(find.textContaining('扫描失败'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
