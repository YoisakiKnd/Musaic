import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/auth/auth_capability.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/features/lyrics/application/lyrics_provider.dart';
import 'package:musaic/features/lyrics/data/lyrics_cache_repository.dart';

/// 歌词磁盘缓存（S6 第一步）。
///
/// 核心契约：
/// 1. 二次进播放页**零网络请求**（设计文档 §5 S6 验收标准）；
/// 2. 只缓存「有歌词」——渠道把网络失败吞成 null，缓存 null 会把一次断网
///    固化成长期无歌词；
/// 3. 本地文件不缓存（用户改了 .lrc 要立即生效）；
/// 4. 过期 / 损坏视为未命中，超容量淘汰最旧。
void main() {
  late Directory tempDir;
  late LazyBox<String> box;
  var now = DateTime(2026, 10, 1);

  LyricsCacheRepository makeRepo({int capacity = 10}) =>
      LyricsCacheRepository(box: box, capacity: capacity, clock: () => now);

  LyricBundle bundle(String text) => LyricBundle(
    lines: [LyricLine(text: text, start: const Duration(seconds: 1))],
  );

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_lyrics_cache');
    Hive.init(tempDir.path);
    box = await Hive.openLazyBox<String>('test_lyrics_cache');
  });

  tearDownAll(() async {
    await box.close();
    await tempDir.delete(recursive: true);
  });

  setUp(() async {
    await box.clear();
    now = DateTime(2026, 10, 1);
  });

  group('LyricsCacheRepository', () {
    test('写入后可读回', () async {
      final repo = makeRepo();
      await repo.write('netease:1', bundle('晴天'));
      expect((await repo.read('netease:1'))!.lines.single.text, '晴天');
      expect(repo.count, 1);
    });

    test('写入尚未落盘时也能读到（懒加载 Box 的读后写一致性）', () async {
      final repo = makeRepo();
      final pending = repo.write('netease:2', bundle('稻香'));
      expect((await repo.read('netease:2'))!.lines.single.text, '稻香');
      await pending;
      expect((await repo.read('netease:2'))!.lines.single.text, '稻香');
    });

    test('空歌词不写入', () async {
      final repo = makeRepo();
      await repo.write('netease:1', LyricBundle(lines: const []));
      expect(repo.count, 0);
    });

    test('超过有效期视为未命中', () async {
      final repo = makeRepo();
      await repo.write('netease:1', bundle('晴天'));
      now = now.add(
        LyricsCacheRepository.defaultMaxAge + const Duration(hours: 1),
      );
      expect(await repo.read('netease:1'), isNull);
    });

    test('损坏条目视为未命中而不是抛异常', () async {
      final repo = makeRepo();
      await box.put('netease:bad1', 'not-a-timestamp');
      await box.put('netease:bad2', '${now.millisecondsSinceEpoch}\n{oops');
      expect(await repo.read('netease:bad1'), isNull);
      expect(await repo.read('netease:bad2'), isNull);
    });

    test('超容量时淘汰最旧条目，保留最新', () async {
      final repo = makeRepo(capacity: 10);
      for (var i = 0; i < 11; i++) {
        now = now.add(const Duration(minutes: 1));
        await repo.write('netease:$i', bundle('line $i'));
      }
      // 一次淘汰到 90%（9 条），最旧的 0、1 被删
      expect(repo.count, 9);
      expect(await repo.read('netease:0'), isNull);
      expect(await repo.read('netease:1'), isNull);
      expect(await repo.read('netease:10'), isNotNull);
    });

    test('本地文件不走缓存', () {
      expect(
        LyricsCacheRepository.isCacheable(
          const Track(id: 'x', sourceId: 'local', title: 't', artist: 'a'),
        ),
        isFalse,
      );
      expect(
        LyricsCacheRepository.isCacheable(
          const Track(id: 'x', sourceId: 'netease', title: 't', artist: 'a'),
        ),
        isTrue,
      );
    });
  });

  group('lyricsProvider 接缓存', () {
    late _LyricsSource source;
    late _LyricsSource localSource;
    late ProviderContainer container;

    setUp(() {
      source = _LyricsSource('netease');
      localSource = _LyricsSource('local');
      final registry =
          SourceRegistry()
            ..register(source)
            ..register(localSource);
      container = ProviderContainer(
        overrides: [
          sourceRegistryProvider.overrideWithValue(registry),
          lyricsCacheRepositoryProvider.overrideWithValue(makeRepo()),
        ],
      );
    });

    tearDown(() => container.dispose());

    /// 模拟「进入播放页 → 退出（autoDispose 释放）」一次完整周期。
    Future<LyricBundle?> visit(Track track) async {
      final sub = container.listen(lyricsProvider(track), (_, _) {});
      final result = await container.read(lyricsProvider(track).future);
      sub.close();
      await Future<void>.delayed(Duration.zero); // 让 autoDispose 生效、写盘完成
      return result;
    }

    const track = Track(
      id: '1',
      sourceId: 'netease',
      title: '晴天',
      artist: '周杰伦',
    );

    test('二次进入命中缓存，零渠道请求', () async {
      source.result = bundle('故事的小黄花');
      expect((await visit(track))!.lines.single.text, '故事的小黄花');
      expect((await visit(track))!.lines.single.text, '故事的小黄花');
      expect(source.calls, 1);
    });

    test('渠道返回 null（可能是断网）不缓存，下次仍会重试', () async {
      source.result = null;
      expect(await visit(track), isNull);
      source.result = bundle('恢复了');
      expect((await visit(track))!.lines.single.text, '恢复了');
      expect(source.calls, 2);
    });

    test('本地文件每次都读渠道（.lrc 修改立即生效）', () async {
      const local = Track(id: 'p', sourceId: 'local', title: 't', artist: 'a');
      localSource.result = bundle('v1');
      await visit(local);
      localSource.result = bundle('v2');
      expect((await visit(local))!.lines.single.text, 'v2');
      expect(localSource.calls, 2);
    });

    test('未注入缓存时直接走渠道（缓存只是优化）', () async {
      final registry = SourceRegistry()..register(source);
      final bare = ProviderContainer(
        overrides: [sourceRegistryProvider.overrideWithValue(registry)],
      );
      addTearDown(bare.dispose);
      source.result = bundle('无缓存');
      final sub = bare.listen(lyricsProvider(track), (_, _) {});
      expect(
        (await bare.read(lyricsProvider(track).future))!.lines.single.text,
        '无缓存',
      );
      sub.close();
    });
  });
}

class _LyricsSource extends MusicSource {
  _LyricsSource(this._id)
    : super(credentialReader: () async => const <String, String>{});

  final String _id;
  LyricBundle? result;
  int calls = 0;

  @override
  String get sourceId => _id;

  @override
  String get displayName => _id;

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
      const ResolvedStream(url: '/x.mp3', isLocalFile: true);

  @override
  Future<LyricBundle?> fetchLyrics(Track track) async {
    calls++;
    return result;
  }
}
