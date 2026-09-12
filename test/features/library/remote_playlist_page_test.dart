import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/auth/auth_capability.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/error/source_exception.dart';
import 'package:musaic/core/model/remote_playlist.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/capabilities.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/theme/app_tokens.dart';
import 'package:musaic/features/library/remote_playlist_page.dart';

/// 渠道账号歌单详情页（T2 覆盖率补强，该文件此前 0%）。
///
/// 重点验证 **B6 的契约**：加载失败必须可见且**可原地重试**。
/// 原实现把 Future 存在 State 字段里，失败后只能退出页面重进——
/// 这是用户可感知的缺陷，不是实现细节。
void main() {
  Track song(String id, {String title = '海阔天空', Duration? duration}) => Track(
    id: id,
    sourceId: 'fake',
    title: title,
    artist: 'Beyond',
    duration: duration,
  );

  const playlist = RemotePlaylist(
    sourceId: 'fake',
    id: 'pl-1',
    name: '我的歌单',
    trackCount: 2,
  );

  Widget host(_StubPlaylistSource source) {
    final registry = SourceRegistry()..register(source);
    return ProviderScope(
      overrides: [sourceRegistryProvider.overrideWithValue(registry)],
      child: MaterialApp(
        theme: AppTokens.darkTheme,
        home: const RemotePlaylistPage(playlist: playlist),
      ),
    );
  }

  group('加载成功', () {
    testWidgets('渲染歌单名与曲目数', (tester) async {
      final source = _StubPlaylistSource(tracks: [song('1'), song('2')]);

      await tester.pumpWidget(host(source));
      await tester.pumpAndSettle();

      expect(find.text('我的歌单'), findsOneWidget);
      expect(find.text('2 首'), findsOneWidget);
      expect(find.text('播放全部'), findsOneWidget);
    });

    testWidgets('逐条渲染曲目（标题 / 歌手 / 序号）', (tester) async {
      final source = _StubPlaylistSource(
        tracks: [song('1', title: '第一首'), song('2', title: '第二首')],
      );

      await tester.pumpWidget(host(source));
      await tester.pumpAndSettle();

      expect(find.text('第一首'), findsOneWidget);
      expect(find.text('第二首'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Beyond'), findsNWidgets(2));
    });

    testWidgets('有时长时显示 mm:ss，无时长不显示', (tester) async {
      final source = _StubPlaylistSource(
        tracks: [
          song('1', duration: const Duration(minutes: 3, seconds: 5)),
          song('2'),
        ],
      );

      await tester.pumpWidget(host(source));
      await tester.pumpAndSettle();

      expect(find.text('3:05'), findsOneWidget);
    });

    testWidgets('空歌单显示空态而非空白列表', (tester) async {
      final source = _StubPlaylistSource(tracks: const []);

      await tester.pumpWidget(host(source));
      await tester.pumpAndSettle();

      expect(find.text('歌单是空的'), findsOneWidget);
      expect(find.text('播放全部'), findsNothing);
    });
  });

  group('加载失败可重试（B6 契约）', () {
    testWidgets('失败时显示原因与「重试」按钮', (tester) async {
      final source = _StubPlaylistSource(
        failure: NetworkSourceException('歌单加载失败：网络异常', sourceId: 'fake'),
      );

      await tester.pumpWidget(host(source));
      await tester.pumpAndSettle();

      expect(find.text('歌单加载失败：网络异常'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
    });

    testWidgets('点击「重试」后原地重新拉取并渲染（无需退出页面）', (tester) async {
      final source = _StubPlaylistSource(
        failure: NetworkSourceException('网络异常', sourceId: 'fake'),
      );

      await tester.pumpWidget(host(source));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);

      // 模拟网络恢复
      source.failure = null;
      source.tracks = [song('1', title: '恢复了')];

      await tester.tap(find.widgetWithText(FilledButton, '重试'));
      await tester.pumpAndSettle();

      expect(find.text('恢复了'), findsOneWidget, reason: '重试必须原地生效，这是 B6 修复的核心');
      expect(find.widgetWithText(FilledButton, '重试'), findsNothing);
    });

    testWidgets('未知异常也给出可读文案而非原始堆栈', (tester) async {
      final source = _StubPlaylistSource(failure: StateError('boom'));

      await tester.pumpWidget(host(source));
      await tester.pumpAndSettle();

      expect(find.textContaining('加载失败'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
    });

    testWidgets('渠道不支持该能力时降级为空列表（不是错误）', (tester) async {
      // 注册一个**不实现** RemotePlaylistCapable 的渠道
      final registry = SourceRegistry()..register(_PlainSource());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sourceRegistryProvider.overrideWithValue(registry)],
          child: MaterialApp(
            theme: AppTokens.darkTheme,
            home: const RemotePlaylistPage(
              playlist: RemotePlaylist(
                sourceId: 'plain',
                id: 'x',
                name: '不支持',
                trackCount: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('歌单是空的'),
        findsOneWidget,
        reason: '能力缺失是「空」而非「错误」，不该给用户报错',
      );
      expect(find.widgetWithText(FilledButton, '重试'), findsNothing);
    });
  });
}

/// 可控的账号歌单渠道：成功 / 失败 / 恢复由测试驱动。
class _StubPlaylistSource extends _PlainSource
    implements RemotePlaylistCapable {
  _StubPlaylistSource({this.tracks = const [], this.failure});

  List<Track> tracks;
  Object? failure;

  @override
  String get sourceId => 'fake';

  @override
  String get displayName => '假渠道';

  @override
  Future<List<RemotePlaylist>> fetchRemotePlaylists(String userId) async =>
      const <RemotePlaylist>[];

  @override
  Future<List<Track>> fetchRemotePlaylistTracks(String playlistId) async {
    final error = failure;
    if (error != null) throw error;
    return tracks;
  }
}

/// 最小渠道实现（**不**实现 RemotePlaylistCapable）。
///
/// `MusicSource` 是抽象类，必须 `extends`；只需实现页面真正会调用的成员，
/// 其余用 noSuchMethod 兜底——一旦页面新增了对渠道的调用，
/// 测试会立刻以 UnimplementedError 暴露，而不是被静默忽略。
class _PlainSource extends MusicSource {
  _PlainSource()
    : super(credentialReader: () async => const <String, String>{});

  @override
  String get sourceId => 'plain';

  @override
  String get displayName => '普通渠道';

  @override
  AuthCapability get authCapability => AuthCapability.noAuth;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试替身未实现：${invocation.memberName}');
}
