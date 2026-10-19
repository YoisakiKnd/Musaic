import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';
import 'package:musaic/core/auth/auth_capability.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/error/source_exception.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/network/network_status.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/features/player/audio_handler.dart';
import 'package:musaic/features/player/data/resume_repository.dart';
import 'package:musaic/features/player/player_notifier.dart';
import 'package:musaic/features/settings/settings_providers.dart';

/// 日常使用中的播放健壮性：
///
/// 1. 播放中途出错（断流 / 签名地址过期）→ 从断点重新加载，有次数上限；
/// 2. 出错后点播放键 → 重新加载，而不是 `play()` 一个空播放器；
/// 3. 渠道只给试听片段 → 优先换其它渠道的完整版本，没有才播片段并提示；
/// 4. 网络错误不自动跳歌（断网时不把整个队列刷完）；
/// 5. 搜索结果点歌（[PlayerNotifier.playNow]）保留原队列。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box<String> resumeBox;
  late Box<String> settingsBox;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_robust_test');
    Hive.init(tempDir.path);
    resumeBox = await Hive.openBox<String>('robust_resume');
    settingsBox = await Hive.openBox<String>('robust_settings');
  });

  tearDownAll(() async {
    await resumeBox.close();
    await settingsBox.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  setUp(() async {
    await settingsBox.clear();
    await resumeBox.clear();
  });

  late _FakePlayer player;
  late StreamController<bool> network;

  ProviderContainer containerWith(List<_ScriptedSource> sources) {
    player = _FakePlayer();
    network = StreamController<bool>();
    return ProviderContainer(
      overrides: [
        networkOnlineProvider.overrideWith((ref) => network.stream),
        audioHandlerProvider.overrideWithValue(_NoopHandler(player: player)),
        resumeRepositoryProvider.overrideWithValue(
          ResumeRepository(box: resumeBox),
        ),
        appSettingsRepositoryProvider.overrideWithValue(
          AppSettingsRepository(box: settingsBox),
        ),
        sourceRegistryProvider.overrideWith((ref) {
          final registry = SourceRegistry();
          for (final s in sources) {
            registry.register(s);
          }
          return registry;
        }),
      ],
    );
  }

  Track song(String sourceId, String id, {String title = '海阔天空'}) => Track(
    id: id,
    sourceId: sourceId,
    title: title,
    artist: 'Beyond',
    duration: const Duration(minutes: 4),
  );

  group('播放中途出错的恢复', () {
    test('断流后从断点重新解析并继续播放', () async {
      final source = _ScriptedSource('a');
      final container = containerWith([source]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);

      await notifier.playQueue([song('a', '1')]);
      expect(source.resolveCount, 1);
      notifier.debugSeekStateForTest(const Duration(seconds: 42));

      notifier.debugPlaybackError(Exception('connection reset'));
      await pumpEventQueue();

      expect(source.resolveCount, 2, reason: '签名地址可能已过期，必须重新解析');
      expect(player.lastInitialPosition, const Duration(seconds: 42));
      expect(notifier.state.playing, isTrue);
      expect(notifier.state.error, isNull);
    });

    test('同一首反复出错：超过上限后停下报错，不无限重试', () async {
      final source = _ScriptedSource('a');
      final container = containerWith([source]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);

      await notifier.playQueue([song('a', '1')]);
      for (var i = 0; i < 3; i++) {
        notifier.debugPlaybackError(Exception('boom'));
        await pumpEventQueue();
      }

      expect(source.resolveCount, 3, reason: '首次加载 + 2 次恢复');
      expect(notifier.state.playing, isFalse);
      expect(notifier.state.error, contains('播放中断'));
    });

    test('恢复时渠道不可用：停在本曲报错，不静默跳到下一首', () async {
      final source = _ScriptedSource('a');
      final container = containerWith([source]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);

      await notifier.playQueue([song('a', '1'), song('a', '2', title: '光辉岁月')]);
      source.failure = UnavailableStreamException('地址失效');
      notifier.debugPlaybackError(Exception('403'));
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(notifier.state.current?.id, '1');
      expect(notifier.state.error, isNotNull);
    });
  });

  group('出错后点播放键', () {
    test('加载失败后再点播放会重新加载（而不是 play 一个空播放器）', () async {
      final source = _ScriptedSource('a')
        ..failure = NetworkSourceException('断网');
      final container = containerWith([source]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);

      await notifier.playQueue([song('a', '1')]);
      expect(notifier.state.error, isNotNull);

      source.failure = null; // 网络恢复
      await notifier.toggle();

      expect(source.resolveCount, 2);
      expect(notifier.state.playing, isTrue);
      expect(notifier.state.error, isNull);
    });

    test('通知栏 / 耳机的播放键走同一条路径', () async {
      final source = _ScriptedSource('a')
        ..failure = NetworkSourceException('断网');
      final container = containerWith([source]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);
      final handler = container.read(audioHandlerProvider);

      await notifier.playQueue([song('a', '1')]);
      source.failure = null;
      await handler.play();

      expect(notifier.state.playing, isTrue);
    });
  });

  group('网络恢复后自动续播', () {
    Future<void> goOnline() async {
      network.add(true);
      await pumpEventQueue();
    }

    test('断网导致加载失败，网络恢复后自动重新播放', () async {
      final source = _ScriptedSource('a')
        ..failure = NetworkSourceException('断网');
      final container = containerWith([source]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);
      network.add(false);
      await pumpEventQueue();

      await notifier.playQueue([song('a', '1')]);
      expect(notifier.state.playing, isFalse);

      source.failure = null;
      await goOnline();

      expect(source.resolveCount, 2);
      expect(notifier.state.playing, isTrue);
    });

    test('非网络原因的失败，网络变化时不自动重试', () async {
      final source = _ScriptedSource('a')
        ..failure = UnavailableStreamException('无版权');
      final container = containerWith([source]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);
      network.add(false);
      await pumpEventQueue();

      await notifier.playQueue([song('a', '1')]);
      await goOnline();

      expect(source.resolveCount, 1);
    });
  });

  group('网络错误不自动跳歌', () {
    test('断网时停在当前曲等待重试，不把队列逐首刷过去', () async {
      final source = _ScriptedSource('a')
        ..failure = NetworkSourceException('断网');
      final container = containerWith([source]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);

      await notifier.playQueue([
        song('a', '1'),
        song('a', '2', title: '光辉岁月'),
        song('a', '3', title: '真的爱你'),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(notifier.state.current?.id, '1');
      expect(source.resolveCount, 1);
    });

    test('无版权仍然自动跳到下一首（个别曲目不可播是常态）', () async {
      final source =
          _ScriptedSource('a')
            ..failingIds = {'1'}
            ..failure = UnavailableStreamException('无版权');
      final container = containerWith([source]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);

      await notifier.playQueue([song('a', '1'), song('a', '2', title: '光辉岁月')]);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(notifier.state.current?.id, '2');
      expect(notifier.state.playing, isTrue);
    });
  });

  group('换源后仍失败的提示', () {
    test('说明试过哪些渠道，并给出最后一个渠道的原因', () async {
      final a = _ScriptedSource('a', displayName: 'QQ 音乐')
        ..failure = UnavailableStreamException('QQ 无版权');
      final b = _ScriptedSource('b', displayName: '酷狗音乐')
        ..failure = UnavailableStreamException('请先登录酷狗');
      final container = containerWith([a, b]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);

      await notifier.playQueue([song('a', '1'), song('b', '2', title: '海阔天空')]);

      expect(notifier.state.error, contains('QQ 音乐'));
      expect(notifier.state.error, contains('酷狗音乐'));
      expect(notifier.state.error, contains('请先登录酷狗'));
    });

    test('没有换过源时保持渠道原话', () async {
      final a = _ScriptedSource('a', displayName: 'QQ 音乐')
        ..failure = UnavailableStreamException('QQ 无版权');
      final container = containerWith([a]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);

      await notifier.playQueue([song('a', '1')]);
      expect(notifier.state.error, 'QQ 无版权');
    });
  });

  group('试听片段', () {
    test('有其它渠道的完整版本时优先播放完整版', () async {
      final preview = _ScriptedSource('a', displayName: '渠道A')..preview = true;
      final full = _ScriptedSource('b', displayName: '渠道B');
      final container = containerWith([preview, full]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);

      await notifier.playQueue([song('a', '1'), song('b', '2')]);

      expect(player.lastUrl, 'b:2');
      expect(notifier.state.notice, contains('渠道B'));
    });

    test('只有试听片段时照常播放并提示用户', () async {
      final preview = _ScriptedSource('a', displayName: '渠道A')..preview = true;
      final container = containerWith([preview]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);

      await notifier.playQueue([song('a', '1')]);

      expect(player.lastUrl, 'a:1');
      expect(notifier.state.playing, isTrue);
      expect(notifier.state.notice, contains('试听'));
    });
  });

  group('looksLikePreviewClip', () {
    test('4 分钟的歌只加载到 30 秒：判为片段', () {
      expect(
        looksLikePreviewClip(
          expected: const Duration(minutes: 4),
          actual: const Duration(seconds: 30),
        ),
        isTrue,
      );
    });

    test('时长接近或未知：不判为片段', () {
      expect(
        looksLikePreviewClip(
          expected: const Duration(minutes: 4),
          actual: const Duration(minutes: 3, seconds: 50),
        ),
        isFalse,
      );
      expect(
        looksLikePreviewClip(
          expected: null,
          actual: const Duration(seconds: 30),
        ),
        isFalse,
      );
      expect(
        looksLikePreviewClip(
          expected: const Duration(seconds: 70),
          actual: const Duration(seconds: 30),
        ),
        isFalse,
        reason: '本身就很短的曲目不做判断',
      );
    });
  });

  group('随机播放', () {
    test('开启随机模式并以整个列表为队列', () async {
      final source = _ScriptedSource('a');
      final container = containerWith([source]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);

      final tracks = [
        for (var i = 0; i < 5; i++) song('a', '$i', title: '歌$i'),
      ];
      await notifier.shufflePlay(tracks);

      expect(notifier.state.shuffleOn, isTrue);
      expect(notifier.state.queue, hasLength(5));
      expect(notifier.state.playing, isTrue);
      expect(
        container.read(appSettingsRepositoryProvider).shuffleOn,
        isTrue,
        reason: '随机模式要持久化，与手动开关一致',
      );
      expect(notifier.debugShuffleOrder, hasLength(5));
      expect(
        notifier.debugShuffleOrder!.first,
        notifier.state.currentIndex,
        reason: '当前曲必须在洗牌序列头部，否则下一首会重复播放它',
      );
    });
  });

  group('搜索结果点歌（playNow）', () {
    test('保留原队列，把这首插到当前曲之后立即播放', () async {
      final source = _ScriptedSource('a');
      final container = containerWith([source]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);

      await notifier.playQueue([
        song('a', 'q1', title: '光辉岁月'),
        song('a', 'q2', title: '真的爱你'),
      ]);
      final results = [song('a', 'r1'), song('a', 'r2', title: '海阔天空 (Live)')];
      await notifier.playNow(results.first, alternativesPool: results);

      expect(notifier.state.queue.map((t) => t.id), ['q1', 'r1', 'q2']);
      expect(notifier.state.current?.id, 'r1');
    });

    test('空队列时只播这一首，不把整页结果塞进队列', () async {
      final source = _ScriptedSource('a');
      final container = containerWith([source]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);

      final results = [song('a', 'r1'), song('a', 'r2', title: '光辉岁月')];
      await notifier.playNow(results.first, alternativesPool: results);

      expect(notifier.state.queue.map((t) => t.id), ['r1']);
    });

    test('结果里其它渠道的同一首仍可作为换源候选', () async {
      final a = _ScriptedSource('a')
        ..failure = UnavailableStreamException('无版权');
      final b = _ScriptedSource('b');
      final container = containerWith([a, b]);
      addTearDown(container.dispose);
      final notifier = container.read(playerNotifierProvider.notifier);

      final results = [song('a', '1'), song('b', '2')];
      await notifier.playNow(results.first, alternativesPool: results);

      expect(player.lastUrl, 'b:2');
      expect(notifier.state.queue, hasLength(1));
      expect(notifier.state.playing, isTrue);
    });
  });
}

extension on PlayerNotifier {
  /// 让 state.position 停在某处（模拟播放到一半）。
  void debugSeekStateForTest(Duration position) =>
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      state = state.copyWith(position: position);
}

class _ScriptedSource extends MusicSource {
  _ScriptedSource(this._id, {String? displayName})
    : _displayName = displayName ?? _id,
      super(credentialReader: () async => const <String, String>{});

  final String _id;
  final String _displayName;
  Object? failure;
  Set<String>? failingIds;
  bool preview = false;
  int resolveCount = 0;

  @override
  String get sourceId => _id;

  @override
  String get displayName => _displayName;

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
  Future<ResolvedStream> resolveStream(Track track) async {
    resolveCount++;
    final f = failure;
    if (f != null && (failingIds == null || failingIds!.contains(track.id))) {
      throw f;
    }
    return ResolvedStream(url: '$_id:${track.id}', isPreview: preview);
  }

  @override
  Future<LyricBundle?> fetchLyrics(Track track) async => null;
}

class _FakePlayer extends Mock implements ja.AudioPlayer {
  String? lastUrl;
  Duration? lastInitialPosition;
  bool _playing = false;

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
  bool get playing => _playing;

  @override
  ja.ProcessingState get processingState => ja.ProcessingState.ready;

  @override
  Duration get position => Duration.zero;

  @override
  Duration get bufferedPosition => Duration.zero;

  @override
  Duration? get duration => const Duration(minutes: 4);

  @override
  double get speed => 1.0;

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    lastUrl = url;
    lastInitialPosition = initialPosition;
    return const Duration(minutes: 4);
  }

  @override
  Future<void> play() async => _playing = true;

  @override
  Future<void> pause() async => _playing = false;

  @override
  Future<void> stop() async => _playing = false;

  @override
  Future<void> seek(Duration? position, {int? index}) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}
}

class _NoopHandler extends MusaicAudioHandler {
  _NoopHandler({required super.player});

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}
}
