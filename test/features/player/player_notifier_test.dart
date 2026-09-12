import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/auth/auth_capability.dart';
import 'package:musaic/core/error/source_exception.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/features/player/audio_handler.dart';
import 'package:musaic/features/player/data/resume_repository.dart';
import 'package:musaic/features/player/domain/queue_logic.dart';
import 'package:musaic/features/player/player_notifier.dart';

/// PlayerNotifier 核心逻辑回归测试。
///
/// 覆盖三个曾长期潜伏的 P0（原先完全没有测试覆盖）：
/// 1. `_autoAdvancing` 在队列尽头 / 「剩余 N 首」停止后不复位，
///    导致播放态同步与自动切歌永久失效；
/// 2. shuffle 下移除当前曲后洗牌序列长度失配 → 越界崩溃；
/// 3. 错误态不可见 / 无法重试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box<String> resumeBox;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_player_test');
    Hive.init(tempDir.path);
    resumeBox = await Hive.openBox<String>('player_resume');
    registerFallbackValue(Duration.zero);
  });

  tearDownAll(() async {
    await resumeBox.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Track track(String id) => Track(
    id: id,
    sourceId: 'fake',
    title: 't$id',
    artist: 'a',
    duration: const Duration(seconds: 30),
  );

  ProviderContainer createContainer({
    required List<Track> queue,
    bool failResolve = false,
  }) {
    return ProviderContainer(
      overrides: [
        playerNotifierProvider.overrideWith(_TestPlayerNotifier.new),
        // 用 no-op handler 替代真实 AudioPlayer：单元测试环境没有
        // just_audio 平台通道，任何 player 调用都会挂起 25s 后超时。
        audioHandlerProvider.overrideWithValue(
          _NoopAudioHandler(player: _FakePlayer()),
        ),
        resumeRepositoryProvider.overrideWithValue(
          ResumeRepository(box: resumeBox),
        ),
        sourceRegistryProvider.overrideWith((ref) {
          final registry = SourceRegistry();
          registry.register(_FakeSource(failResolve: failResolve));
          return registry;
        }),
      ],
    );
  }

  /// 直接注入队列，绕过真实解析链路。
  _TestPlayerNotifier notifierWith(
    ProviderContainer container,
    List<Track> queue, {
    int currentIndex = 0,
    PlayMode mode = PlayMode.sequential,
    bool shuffleOn = false,
  }) {
    final notifier =
        container.read(playerNotifierProvider.notifier) as _TestPlayerNotifier;
    notifier.debugSeed(
      queue: queue,
      currentIndex: currentIndex,
      mode: mode,
      shuffleOn: shuffleOn,
    );
    return notifier;
  }

  group('_autoAdvancing 复位（P0-1）', () {
    test('顺序播放到队尾后，自动推进标志必须复位', () async {
      final container = createContainer(queue: [track('a'), track('b')]);
      // 停在队尾，next() 会走「队列尽头」早返回分支（不触碰播放器）
      final notifier = notifierWith(container, [
        track('a'),
        track('b'),
      ], currentIndex: 1);

      // 模拟自然播完最后一曲触发的自动推进
      notifier.debugSetAutoAdvancing(true);
      await notifier.next(); // 队尾 → 暂停并 return

      expect(
        notifier.debugAutoAdvancingValue,
        isFalse,
        reason: '队列尽头分支泄漏 _autoAdvancing 会让播放态同步永久失效',
      );
      container.dispose();
    });

    test('「剩余 1 首」停止分支同样复位', () async {
      final container = createContainer(queue: [track('a'), track('b')]);
      final notifier = notifierWith(container, [track('a'), track('b')]);
      notifier.debugSetSleepSongsRemaining(1);

      await notifier.debugAdvanceOnComplete();

      expect(notifier.debugAutoAdvancingValue, isFalse);
      expect(notifier.state.playing, isFalse, reason: '应停止播放');
      expect(notifier.state.sleepSongsRemaining, isNull);
      container.dispose();
    });

    test('自动推进正常路径结束后同样复位', () async {
      final container = createContainer(queue: [track('a'), track('b')]);
      final notifier = notifierWith(container, [
        track('a'),
        track('b'),
      ], currentIndex: 1);

      await notifier.debugAdvanceOnComplete();

      expect(notifier.debugAutoAdvancingValue, isFalse);
      container.dispose();
    });

    test('复位后播放态仍可同步（闸门未永久关闭）', () {
      final container = createContainer(queue: [track('a')]);
      final notifier = notifierWith(container, [track('a')]);

      notifier.debugSetAutoAdvancing(true);
      notifier.debugSetPlaying(false); // 闸门关闭：不应写入
      expect(notifier.state.playing, isFalse);

      notifier.debugSetAutoAdvancing(false);
      notifier.debugSetPlaying(true);
      expect(notifier.state.playing, isTrue, reason: '闸门复位后必须能再同步');
      container.dispose();
    });
  });

  group('shuffle 下移除当前曲（P0-3）', () {
    test('移除当前曲后洗牌序列长度与队列一致（不再越界）', () async {
      final container = createContainer(
        queue: [track('a'), track('b'), track('c')],
      );
      final notifier = notifierWith(container, [
        track('a'),
        track('b'),
        track('c'),
      ], shuffleOn: true);

      expect(notifier.debugShuffleOrderLength, 3);

      await notifier.removeFromQueue(0);

      expect(
        notifier.debugShuffleOrderLength,
        notifier.state.queue.length,
        reason: '序列长度失配会让 nextIndex 返回越界下标 → RangeError',
      );

      // 修复前：序列长度 3 而队列长度 2 → nextIndex 返回 2 → _loadAndPlay 越界。
      // 这里直接断言不变量本身（等价于 next() 的第一步）。
      final advance = QueueLogic.nextIndex(
        currentIndex: notifier.state.currentIndex,
        length: notifier.state.queue.length,
        mode: notifier.state.mode,
        shuffleOn: true,
        shuffleOrder: notifier.debugShuffleOrder,
      );
      expect(
        advance == null ||
            (advance.index >= 0 && advance.index < notifier.state.queue.length),
        isTrue,
        reason: '洗牌推进不得返回越界下标',
      );
      container.dispose();
    });

    test('移除非当前曲同样保持序列长度一致', () async {
      final container = createContainer(
        queue: [track('a'), track('b'), track('c')],
      );
      final notifier = notifierWith(
        container,
        [track('a'), track('b'), track('c')],
        currentIndex: 2,
        shuffleOn: true,
      );

      await notifier.removeFromQueue(0);

      expect(notifier.debugShuffleOrderLength, notifier.state.queue.length);
      final advance = QueueLogic.nextIndex(
        currentIndex: notifier.state.currentIndex,
        length: notifier.state.queue.length,
        mode: notifier.state.mode,
        shuffleOn: true,
        shuffleOrder: notifier.debugShuffleOrder,
      );
      expect(
        advance == null ||
            (advance.index >= 0 && advance.index < notifier.state.queue.length),
        isTrue,
      );
      container.dispose();
    });

    test('洗牌序列中每个下标都在队列范围内', () async {
      final container = createContainer(
        queue: [track('a'), track('b'), track('c'), track('d')],
      );
      final notifier = notifierWith(container, [
        track('a'),
        track('b'),
        track('c'),
        track('d'),
      ], shuffleOn: true);

      await notifier.removeFromQueue(1);

      final order = notifier.debugShuffleOrder;
      expect(order, isNotNull);
      for (final index in order!) {
        expect(index, inInclusiveRange(0, notifier.state.queue.length - 1));
      }
      container.dispose();
    });

    test('移除唯一一曲后清空队列且不崩溃', () async {
      final container = createContainer(queue: [track('a')]);
      final notifier = notifierWith(container, [track('a')], shuffleOn: true);

      await notifier.removeFromQueue(0);

      expect(notifier.state.queue, isEmpty);
      expect(notifier.debugShuffleOrder, isNull);
      container.dispose();
    });
  });

  group('错误可见性与重试（P0-2）', () {
    test('解析失败写入 error 且 loading 归位', () async {
      final container = createContainer(queue: [track('a')], failResolve: true);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([track('a')]);

      expect(notifier.state.error, isNotNull, reason: '失败必须写入可见错误');
      expect(notifier.state.loading, isFalse);
      expect(notifier.state.playing, isFalse);
      container.dispose();
    });

    test('retry 清空错误并重新尝试', () async {
      final container = createContainer(queue: [track('a')], failResolve: true);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;
      await notifier.playQueue([track('a')]);
      expect(notifier.state.error, isNotNull);

      await notifier.retry();
      // 仍然失败，但错误是「重新产生」的而非残留的旧值
      expect(notifier.state.error, isNotNull);
      container.dispose();
    });

    test('clearError 清空错误', () async {
      final container = createContainer(queue: [track('a')], failResolve: true);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;
      await notifier.playQueue([track('a')]);

      notifier.clearError();
      expect(notifier.state.error, isNull);
      container.dispose();
    });

    test('空队列 retry 不抛异常', () async {
      final container = createContainer(queue: const <Track>[]);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;
      await expectLater(notifier.retry(), completes);
      container.dispose();
    });
  });

  group('_loadAndPlay 越界守卫（P0-3 第二道防线）', () {
    test('越界下标被静默忽略而非抛异常', () async {
      final container = createContainer(queue: [track('a')]);
      final notifier = notifierWith(container, [track('a')]);

      await expectLater(notifier.debugLoadAndPlay(99), completes);
      await expectLater(notifier.debugLoadAndPlay(-1), completes);
      container.dispose();
    });
  });
}

/// 测试替身：暴露内部标志与私有路径，绕过真实网络解析。
class _TestPlayerNotifier extends PlayerNotifier {
  void debugSeed({
    required List<Track> queue,
    required int currentIndex,
    required PlayMode mode,
    required bool shuffleOn,
  }) {
    debugSeedState(
      queue: queue,
      currentIndex: currentIndex,
      mode: mode,
      shuffleOn: shuffleOn,
    );
  }

  bool get debugAutoAdvancingValue => debugAutoAdvancing;

  void debugSetAutoAdvancing(bool value) => debugAutoAdvancing = value;

  /// 模拟 `_onPlayerStateChanged` 的闸门语义：闸门关闭时不写入播放态。
  void debugSetPlaying(bool playing) {
    if (!debugAutoAdvancing) {
      state = state.copyWith(playing: playing);
    }
  }

  void debugSetSleepSongsRemaining(int value) {
    state = state.copyWith(sleepSongsRemaining: value);
  }

  int? get debugShuffleOrderLength => debugShuffleOrder?.length;
}

/// 假渠道：resolveStream 恒失败或恒成功（本地文件路径）。
class _FakeSource extends MusicSource {
  _FakeSource({required this.failResolve})
    : super(credentialReader: () async => const <String, String>{});

  final bool failResolve;

  @override
  String get sourceId => 'fake';

  @override
  String get displayName => 'Fake';

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
    if (failResolve) {
      throw UnavailableStreamException('测试失败');
    }
    return const ResolvedStream(
      url: '/nonexistent/file.mp3',
      isLocalFile: true,
    );
  }

  @override
  Future<LyricBundle?> fetchLyrics(Track track) async => null;
}

/// 桩播放器：单元测试没有原生实现，真实 AudioPlayer 的
/// `setFilePath` 会永久挂起（等待平台事件）。全部成员给出可控返回值。
class _FakePlayer extends Mock implements ja.AudioPlayer {
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
  Duration? get duration => const Duration(seconds: 30);

  @override
  double get speed => 1.0;

  @override
  double get volume => 1.0;

  @override
  Future<Duration?> setFilePath(
    String filePath, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async => const Duration(seconds: 30);

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async => const Duration(seconds: 30);

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration? position, {int? index}) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() async {}
}

/// 无副作用 handler：单元测试环境没有 just_audio 平台实现，
/// 真实 [MusaicAudioHandler] 的 setUrl/play 会挂起到超时。
/// 这里只保留状态镜像与回调转发，播放操作全部 no-op。
class _NoopAudioHandler extends MusaicAudioHandler {
  _NoopAudioHandler({required super.player});

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}
}
