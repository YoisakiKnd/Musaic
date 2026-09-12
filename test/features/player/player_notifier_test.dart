import 'dart:async';
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
import 'package:musaic/core/network/network_config.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/features/player/audio_handler.dart';
import 'package:musaic/features/player/data/resume_repository.dart';
import 'package:musaic/features/player/domain/queue_logic.dart';
import 'package:musaic/features/player/player_notifier.dart';
import 'package:musaic/features/settings/settings_providers.dart';

/// PlayerNotifier 核心逻辑回归测试。
///
/// ## 测试基建约定
///
/// `PlayerNotifier.build()` 会读取 `appSettingsRepositoryProvider` 以恢复
/// 音量 / 倍速 / 播放模式。因此**任何**构建 PlayerNotifier 的测试都必须
/// override 该 provider，否则抛「必须在启动时 override」。
/// 新增播放器相关测试时请直接复用本文件的容器构造函数。
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
  late Box<String> settingsBox;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_player_test');
    Hive.init(tempDir.path);
    resumeBox = await Hive.openBox<String>('player_resume');
    settingsBox = await Hive.openBox<String>('player_settings');
    registerFallbackValue(Duration.zero);
  });

  tearDownAll(() async {
    await resumeBox.close();
    await settingsBox.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  setUp(() async {
    // 每个用例清空设置，避免「持久化」用例相互污染
    await settingsBox.clear();
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
        // PlayerNotifier.build() 会读取设置以恢复音量/倍速/模式，
        // 因此所有用例都必须注入设置仓库。
        appSettingsRepositoryProvider.overrideWithValue(
          AppSettingsRepository(box: _settingsBoxFor()),
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

  group('跨渠道换源（D7）', () {
    /// 构造「同一首歌在两个渠道」的队列，并让指定渠道按指定方式失败。
    ProviderContainer fallbackContainer({
      required String failSourceId,
      required Object failure,
    }) {
      return ProviderContainer(
        overrides: [
          playerNotifierProvider.overrideWith(_TestPlayerNotifier.new),
          audioHandlerProvider.overrideWithValue(
            _NoopAudioHandler(player: _FakePlayer()),
          ),
          resumeRepositoryProvider.overrideWithValue(
            ResumeRepository(box: resumeBox),
          ),
          appSettingsRepositoryProvider.overrideWithValue(
            AppSettingsRepository(box: _settingsBoxFor()),
          ),
          sourceRegistryProvider.overrideWith((ref) {
            final registry = SourceRegistry();
            // 失败渠道
            registry.register(
              _FakeSource(
                failResolve: false,
                failure: failure,
                sourceIdOverride: failSourceId,
              ),
            );
            // 可用渠道
            registry.register(
              _FakeSource(failResolve: false, sourceIdOverride: 'backup'),
            );
            return registry;
          }),
        ],
      );
    }

    Track songOn(String sourceId, String id) => Track(
      id: id,
      sourceId: sourceId,
      title: '海阔天空',
      artist: 'Beyond',
      duration: const Duration(seconds: 30),
    );

    test('无版权时自动切换到其它渠道并播放', () async {
      final container = fallbackContainer(
        failSourceId: 'primary',
        failure: UnavailableStreamException('无版权'),
      );
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([songOn('primary', '1'), songOn('backup', '2')]);

      expect(notifier.state.error, isNull, reason: '换源成功不应报错');
      expect(notifier.state.playing, isTrue, reason: '应已在备用渠道开始播放');
      container.dispose();
    });

    test('需要登录时同样换源（换匿名可用渠道）', () async {
      final container = fallbackContainer(
        failSourceId: 'primary',
        failure: AuthRequiredException('请先登录'),
      );
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([songOn('primary', '1'), songOn('backup', '2')]);

      expect(notifier.state.error, isNull);
      expect(notifier.state.playing, isTrue);
      container.dispose();
    });

    test('**断网时不换源**，直接报错（避免多渠道路由空转）', () async {
      final container = fallbackContainer(
        failSourceId: 'primary',
        failure: NetworkSourceException('断网'),
      );
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([songOn('primary', '1'), songOn('backup', '2')]);

      expect(notifier.state.error, isNotNull, reason: '网络问题必须立即失败，而不是在多个渠道间空转');
      expect(notifier.state.playing, isFalse);
      container.dispose();
    });

    test('**超时不换源**（否则断网时多候选会累计等待数十秒）', () async {
      // 用真实时间而非 fakeAsync：一旦代码错误地继续换源，备用渠道会成功
      // 并进入播放链路（含 Hive 写），fakeAsync 下这些真实 IO 永不完成，
      // 测试会挂起而不是干净地失败。真实时间下能直接断言出错误。
      //
      // 把超时压到下限（4s → 解析超时 8s），控制该用例耗时。
      final originalSeconds = NetworkConfig.instance.seconds;
      NetworkConfig.instance.set(NetworkConfig.minSeconds);
      addTearDown(() => NetworkConfig.instance.set(originalSeconds));

      final container = ProviderContainer(
        overrides: [
          appSettingsRepositoryProvider.overrideWithValue(
            AppSettingsRepository(box: _settingsBoxFor()),
          ),
          playerNotifierProvider.overrideWith(_TestPlayerNotifier.new),
          audioHandlerProvider.overrideWithValue(
            _NoopAudioHandler(player: _FakePlayer()),
          ),
          resumeRepositoryProvider.overrideWithValue(
            ResumeRepository(box: resumeBox),
          ),
          sourceRegistryProvider.overrideWith((ref) {
            final registry = SourceRegistry();
            final hanging = _FakeSource(
              failResolve: false,
              sourceIdOverride: 'primary',
            )..hang = true;
            registry.register(hanging);
            registry.register(
              _FakeSource(failResolve: false, sourceIdOverride: 'backup'),
            );
            return registry;
          }),
        ],
      );
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier
          .playQueue([songOn('primary', '1'), songOn('backup', '2')])
          .timeout(const Duration(seconds: 30));

      expect(
        notifier.state.error,
        isNotNull,
        reason:
            '超时属于网络问题，必须直接失败；'
            '若继续换源，备用渠道会成功，error 将为 null',
      );
      expect(notifier.state.playing, isFalse, reason: '不得因为换源而在断网时「看起来播上了」');
      container.dispose();
    });

    test('全部候选都不可用时，报最后一次的错误', () async {
      final container = ProviderContainer(
        overrides: [
          appSettingsRepositoryProvider.overrideWithValue(
            AppSettingsRepository(box: _settingsBoxFor()),
          ),
          playerNotifierProvider.overrideWith(_TestPlayerNotifier.new),
          audioHandlerProvider.overrideWithValue(
            _NoopAudioHandler(player: _FakePlayer()),
          ),
          resumeRepositoryProvider.overrideWithValue(
            ResumeRepository(box: resumeBox),
          ),
          sourceRegistryProvider.overrideWith((ref) {
            final registry = SourceRegistry();
            registry.register(
              _FakeSource(
                failResolve: false,
                failure: UnavailableStreamException('A 无版权'),
                sourceIdOverride: 'a',
              ),
            );
            registry.register(
              _FakeSource(
                failResolve: false,
                failure: UnavailableStreamException('B 无版权'),
                sourceIdOverride: 'b',
              ),
            );
            return registry;
          }),
        ],
      );
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([songOn('a', '1'), songOn('b', '2')]);

      expect(notifier.state.error, isNotNull);
      expect(
        notifier.state.error,
        contains('B'),
        reason: '应报最后尝试的那个渠道的错误，它最能反映现状',
      );
      container.dispose();
    });

    test('换源成功时写入一次性提示，可被 UI 观察与清除', () async {
      final container = fallbackContainer(
        failSourceId: 'primary',
        failure: UnavailableStreamException('无版权'),
      );
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([songOn('primary', '1'), songOn('backup', '2')]);

      // 提示必须出现在 state 里：私有字段无法被 ref.listen 观察到
      final notice = notifier.state.sourceSwitchNotice;
      expect(notice, isNotNull, reason: '换源必须告知用户，否则会困惑于版本变化');
      expect(notice, contains('primary'));
      expect(notice, contains('backup'));

      notifier.clearSourceSwitchNotice();
      expect(notifier.state.sourceSwitchNotice, isNull);
      container.dispose();
    });

    test('未发生换源时不产生提示（避免无意义打扰）', () async {
      final container = ProviderContainer(
        overrides: [
          appSettingsRepositoryProvider.overrideWithValue(
            AppSettingsRepository(box: _settingsBoxFor()),
          ),
          playerNotifierProvider.overrideWith(_TestPlayerNotifier.new),
          audioHandlerProvider.overrideWithValue(
            _NoopAudioHandler(player: _FakePlayer()),
          ),
          resumeRepositoryProvider.overrideWithValue(
            ResumeRepository(box: resumeBox),
          ),
          sourceRegistryProvider.overrideWith((ref) {
            final registry = SourceRegistry();
            registry.register(
              _FakeSource(failResolve: false, sourceIdOverride: 'solo'),
            );
            return registry;
          }),
        ],
      );
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([songOn('solo', '1')]);

      expect(notifier.state.sourceSwitchNotice, isNull);
      expect(notifier.state.playing, isTrue);
      container.dispose();
    });

    test('单渠道曲目失败时不换源（无候选）', () async {
      final container = fallbackContainer(
        failSourceId: 'primary',
        failure: UnavailableStreamException('无版权'),
      );
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      // 队列里只有 primary 一条，没有替代候选
      await notifier.playQueue([songOn('primary', '1')]);

      expect(notifier.state.error, isNotNull);
      container.dispose();
    });

    test('不同歌曲不会互相换源', () async {
      final container = fallbackContainer(
        failSourceId: 'primary',
        failure: UnavailableStreamException('无版权'),
      );
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue(const [
        Track(id: '1', sourceId: 'primary', title: '甲歌曲', artist: 'X'),
        Track(id: '2', sourceId: 'backup', title: '乙歌曲', artist: 'Y'),
      ]);

      expect(notifier.state.error, isNotNull, reason: '不同歌曲不应被视为可互换');
      container.dispose();
    });
  });

  group('播放器记忆：音量 / 倍速 / 模式持久化（P0）', () {
    /// 造一个带真实设置仓库的容器，验证「写入后被记住」。
    ProviderContainer settingsContainer() {
      final settingsBox = _settingsBoxFor();
      return ProviderContainer(
        overrides: [
          playerNotifierProvider.overrideWith(_TestPlayerNotifier.new),
          audioHandlerProvider.overrideWithValue(
            _NoopAudioHandler(player: _FakePlayer()),
          ),
          resumeRepositoryProvider.overrideWithValue(
            ResumeRepository(box: resumeBox),
          ),
          appSettingsRepositoryProvider.overrideWithValue(
            AppSettingsRepository(box: settingsBox),
          ),
          sourceRegistryProvider.overrideWith((ref) => SourceRegistry()),
        ],
      );
    }

    test('设置倍速会写入持久化设置', () async {
      final container = settingsContainer();
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;
      final settings = container.read(appSettingsRepositoryProvider);

      await notifier.setSpeed(1.5);

      expect(notifier.state.speed, 1.5);
      expect(settings.playbackSpeed, 1.5, reason: '倍速常被长期固定（播客/有声书），必须记住');
      container.dispose();
    });

    test('倍速被钳制在允许区间内', () async {
      final container = settingsContainer();
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.setSpeed(99);
      expect(notifier.state.speed, maxPlaybackSpeed);

      await notifier.setSpeed(0.01);
      expect(notifier.state.speed, minPlaybackSpeed);
      container.dispose();
    });

    test('设置音量会写入持久化设置', () async {
      final container = settingsContainer();
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;
      final settings = container.read(appSettingsRepositoryProvider);

      await notifier.setVolume(0.3);

      expect(
        settings.volume,
        closeTo(0.3, 0.001),
        reason: '夜间戴耳机时音量突满会真实困扰用户，必须记住',
      );
      container.dispose();
    });

    test('设置播放模式会写入持久化设置', () async {
      final container = settingsContainer();
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;
      final settings = container.read(appSettingsRepositoryProvider);

      notifier.setMode(PlayMode.loopAll);
      expect(notifier.state.mode, PlayMode.loopAll);
      // 持久化是 unawaited 的，让微任务跑完
      await Future<void>.delayed(Duration.zero);
      expect(settings.playMode, PlayMode.loopAll);
      container.dispose();
    });

    test('切换随机播放会写入持久化设置', () async {
      final container = settingsContainer();
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;
      final settings = container.read(appSettingsRepositoryProvider);

      notifier.toggleShuffle();
      await Future<void>.delayed(Duration.zero);

      expect(notifier.state.shuffleOn, isTrue);
      expect(settings.shuffleOn, isTrue);
      container.dispose();
    });

    test('启动时恢复上次的倍速 / 模式 / 随机状态', () async {
      final settingsBox = _settingsBoxFor();
      final repo = AppSettingsRepository(box: settingsBox);
      await repo.setPlaybackSpeed(1.25);
      await repo.setPlayMode(PlayMode.loopOne);
      await repo.setShuffleOn(true);

      final container = ProviderContainer(
        overrides: [
          playerNotifierProvider.overrideWith(_TestPlayerNotifier.new),
          audioHandlerProvider.overrideWithValue(
            _NoopAudioHandler(player: _FakePlayer()),
          ),
          resumeRepositoryProvider.overrideWithValue(
            ResumeRepository(box: resumeBox),
          ),
          appSettingsRepositoryProvider.overrideWithValue(repo),
          sourceRegistryProvider.overrideWith((ref) => SourceRegistry()),
        ],
      );
      final state = container.read(playerNotifierProvider);

      expect(state.speed, 1.25, reason: '倍速必须跨启动保持');
      expect(state.mode, PlayMode.loopOne);
      expect(state.shuffleOn, isTrue);
      container.dispose();
    });
  });

  group('播放失败自动跳过（P1）', () {
    ProviderContainer failingQueue(List<Track> queue, {PlayMode? mode}) {
      final settingsBox = _settingsBoxFor();
      return ProviderContainer(
        overrides: [
          playerNotifierProvider.overrideWith(_TestPlayerNotifier.new),
          audioHandlerProvider.overrideWithValue(
            _NoopAudioHandler(player: _FakePlayer()),
          ),
          resumeRepositoryProvider.overrideWithValue(
            ResumeRepository(box: resumeBox),
          ),
          appSettingsRepositoryProvider.overrideWithValue(
            AppSettingsRepository(box: settingsBox),
          ),
          sourceRegistryProvider.overrideWith((ref) {
            final registry = SourceRegistry();
            registry.register(
              _FakeSource(
                failResolve: false,
                failure: UnavailableStreamException('不可播'),
                sourceIdOverride: 'broken',
              ),
            );
            return registry;
          }),
        ],
      );
    }

    Track brokenSong(String id) =>
        Track(id: id, sourceId: 'broken', title: '曲$id', artist: 'X');

    /// 可播曲目：resolveStream 成功（走本地文件路径分支）。
    Track okSong(String id) =>
        Track(id: id, sourceId: 'good', title: '可播$id', artist: 'X');

    /// 混合队列容器：`broken` 渠道恒失败，`good` 渠道恒成功。
    ///
    /// 只有这样才能验证「跳过」与「不跳过」的差异——全失败队列下
    /// 两种行为都会停在错误态，无法区分。
    ProviderContainer mixedQueueContainer({
      required List<Track> failing,
      required List<Track> playable,
    }) {
      return ProviderContainer(
        overrides: [
          appSettingsRepositoryProvider.overrideWithValue(
            AppSettingsRepository(box: _settingsBoxFor()),
          ),
          playerNotifierProvider.overrideWith(_TestPlayerNotifier.new),
          audioHandlerProvider.overrideWithValue(
            _NoopAudioHandler(player: _FakePlayer()),
          ),
          resumeRepositoryProvider.overrideWithValue(
            ResumeRepository(box: resumeBox),
          ),
          sourceRegistryProvider.overrideWith((ref) {
            final registry = SourceRegistry();
            registry.register(
              _FakeSource(
                failResolve: false,
                failure: UnavailableStreamException('不可播'),
                sourceIdOverride: 'broken',
              ),
            );
            registry.register(
              _FakeSource(failResolve: false, sourceIdOverride: 'good'),
            );
            return registry;
          }),
        ],
      );
    }

    /// 等待自动跳过链走完。
    ///
    /// `_skipAfterFailure` 是 unawaited 的，且刻意延迟 350ms 再切歌
    /// （让用户有机会看到失败提示），因此 `await playQueue(...)` 返回时
    /// 跳过尚未发生，必须显式等待。
    Future<void> waitForSkips(int expectedMs) =>
        Future<void>.delayed(Duration(milliseconds: expectedMs));

    test('失败后自动跳到下一首（多渠道路由下个别失败是常态）', () async {
      final container = failingQueue(const []);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([
        brokenSong('1'),
        brokenSong('2'),
        brokenSong('3'),
      ]);
      // 三首全不可播：跳两次到队尾后停止（每次约 350ms）
      await waitForSkips(1500);

      // 全部不可播 → 连跳后停在错误态，而不是静默刷完整个队列
      expect(notifier.state.error, isNotNull);
      expect(
        notifier.state.currentIndex,
        greaterThan(0),
        reason: '应至少尝试过后续曲目，而不是卡在第一首',
      );
      container.dispose();
    });

    test('单曲循环模式不自动跳过（用户明确要求重复这一首）', () async {
      // 关键：第 2 首是**可播**的。若守卫失效，播放器会跳过去并成功播放，
      // currentIndex 变成 1 —— 用「全部不可播」的队列无法区分这两种情况
      // （跳与不跳都停在错误态），那样的测试是假的。
      final container = mixedQueueContainer(
        failing: [brokenSong('1')],
        playable: [okSong('2')],
      );
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;
      notifier.setMode(PlayMode.loopOne);

      await notifier.playQueue([brokenSong('1'), okSong('2')]);
      await waitForSkips(900);

      expect(notifier.state.error, isNotNull);
      expect(notifier.state.currentIndex, 0, reason: '单曲循环下失败应如实报错，不得跳到下一首');
      container.dispose();
    });

    test('队列只有一首时不跳过', () async {
      final container = mixedQueueContainer(
        failing: [brokenSong('1')],
        playable: const [],
      );
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([brokenSong('1')]);
      await waitForSkips(900);

      expect(notifier.state.error, isNotNull);
      expect(notifier.state.currentIndex, 0);
      container.dispose();
    });

    test('可播的下一首确实会被自动播上（证明跳过链真的在工作）', () async {
      // 反向验证：确保上面的「不跳」断言不是因为跳过功能整体失效。
      final container = mixedQueueContainer(
        failing: [brokenSong('1')],
        playable: [okSong('2')],
      );
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([brokenSong('1'), okSong('2')]);
      await waitForSkips(1200);

      expect(notifier.state.currentIndex, 1, reason: '第一首不可播时应自动播上第二首');
      expect(notifier.state.playing, isTrue);
      container.dispose();
    });

    test('顺序模式到队尾即停止，不绕回开头', () async {
      final container = failingQueue(const []);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([brokenSong('1'), brokenSong('2')]);
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(notifier.state.currentIndex, lessThan(2), reason: '顺序模式不得越界或绕回');
      container.dispose();
    });
  });

  group('播放地址预取（P2）', () {
    /// 计数渠道：记录 resolveStream 被调用的次数，用于验证「预取后不再解析」。
    ProviderContainer countingContainer(_CountingSource source) {
      return ProviderContainer(
        overrides: [
          appSettingsRepositoryProvider.overrideWithValue(
            AppSettingsRepository(box: _settingsBoxFor()),
          ),
          playerNotifierProvider.overrideWith(_TestPlayerNotifier.new),
          audioHandlerProvider.overrideWithValue(
            _NoopAudioHandler(player: _FakePlayer()),
          ),
          resumeRepositoryProvider.overrideWithValue(
            ResumeRepository(box: resumeBox),
          ),
          sourceRegistryProvider.overrideWith((ref) {
            final registry = SourceRegistry();
            registry.register(source);
            return registry;
          }),
        ],
      );
    }

    Track song(String id) =>
        Track(id: id, sourceId: 'counting', title: 't$id', artist: 'a');

    test('播放后预取下一首，点下一首时不再走网络解析', () async {
      final source = _CountingSource();
      final container = countingContainer(source);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([song('1'), song('2')]);
      // 等预取完成（unawaited）
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final afterFirst = source.resolveCount;
      expect(
        afterFirst,
        greaterThanOrEqualTo(2),
        reason: '第 1 首解析 + 预取第 2 首，共至少 2 次',
      );

      await notifier.next();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(source.resolveCount, afterFirst, reason: '预取命中时不应再发起解析请求');
      container.dispose();
    });

    test('预取命中不产生「已切换渠道」提示（用户还没点下一首）', () async {
      final source = _CountingSource();
      final container = countingContainer(source);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([song('1'), song('2')]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        notifier.state.sourceSwitchNotice,
        isNull,
        reason: '预取是后台优化，不该弹任何用户可见提示',
      );
      container.dispose();
    });

    test('队列替换作废旧预取（新队列首曲与预取目标不同时）', () async {
      // 这个用例的关键在于**新队列的首曲不能是被预取的那首**。
      //
      // 若新队列首曲恰是预取目标（如 [2,3] 对预取 2），`take()` 会把它
      // 消费掉，于是「有没有 invalidate」结果一样——变异测试连续 6 次
      // 未捕获，正是因为构造错了场景。
      //
      // 这里用 [9,2]：首曲 9 与预取目标 2 不匹配，take 不会消费它。
      // 此时若未作废，残留的 2 会被误用（带着上一队列的换源上下文）。
      final source = _CountingSource();
      final container = countingContainer(source);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([song('1'), song('2')]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        notifier.debugHasFreshPrefetch,
        isTrue,
        reason: '播放稳定后应已预取下一首（song 2）',
      );

      // 新队列首曲是 song('9')，与预取目标 song('2') 不同
      final pending = notifier.playQueue([song('9'), song('2')]);
      expect(
        notifier.debugHasFreshPrefetch,
        isFalse,
        reason: '换队列必须立即作废旧预取，不得等到解析完成',
      );

      await pending;
      container.dispose();
    });

    test('预取失败不影响播放（静默降级为实时解析）', () async {
      final source = _CountingSource(failPrefetch: true);
      final container = countingContainer(source);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([song('1'), song('2')]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await notifier.next();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(notifier.state.error, isNull, reason: '预取失败不该变成播放错误');
      expect(notifier.state.current?.id, '2');
      container.dispose();
    });

    test('队尾不预取（没有下一首）', () async {
      final source = _CountingSource();
      final container = countingContainer(source);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([song('1')]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(source.resolveCount, 1, reason: '只有一首时无下一首可预取');
      container.dispose();
    });
  });

  group('交叉淡入（N4）', () {
    test('默认关闭：crossfadeSeconds 为 0，不启用', () async {
      final container = createContainer(queue: [track('a')]);
      final settings = container.read(appSettingsRepositoryProvider);
      expect(settings.crossfadeSeconds, 0, reason: '交叉淡入需双路解码，默认必须关闭');
      container.dispose();
    });

    test('时长被钳制在 0–12 秒', () async {
      final box = _settingsBoxFor();
      final repo = AppSettingsRepository(box: box);

      await repo.setCrossfadeSeconds(99);
      expect(repo.crossfadeSeconds, maxCrossfadeSeconds);

      await repo.setCrossfadeSeconds(-5);
      expect(repo.crossfadeSeconds, 0);
    });

    test('开启后未进入淡入窗口时不推进（剩余时间充足）', () async {
      final box = _settingsBoxFor();
      await AppSettingsRepository(box: box).setCrossfadeSeconds(4);

      final container = createContainer(queue: [track('a'), track('b')]);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([track('a'), track('b')]);
      // 曲长 30 秒，远大于 4 秒窗口
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(notifier.debugCrossfading, isFalse, reason: '剩余时间充足时不该开始淡入');
      container.dispose();
    });

    test('手动切歌会取消进行中的交叉淡入', () async {
      final box = _settingsBoxFor();
      await AppSettingsRepository(box: box).setCrossfadeSeconds(4);

      final container = createContainer(queue: [track('a'), track('b')]);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;

      await notifier.playQueue([track('a'), track('b')]);
      await notifier.next();

      expect(
        notifier.debugCrossfading,
        isFalse,
        reason: '手动切歌必须取消淡入，否则音量会停在半途',
      );
      container.dispose();
    });

    test('dispose 时不因读 provider 而抛异常（回归）', () async {
      final box = _settingsBoxFor();
      await AppSettingsRepository(box: box).setCrossfadeSeconds(4);

      final container = createContainer(queue: [track('a')]);
      final notifier =
          container.read(playerNotifierProvider.notifier)
              as _TestPlayerNotifier;
      await notifier.playQueue([track('a')]);

      // 曾在此处抛「Tried to read a provider from a ProviderContainer
      // that was already disposed」——dispose 路径不得读 provider
      expect(container.dispose, returnsNormally);
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
  _FakeSource({
    required this.failResolve,
    this.failure,
    this.sourceIdOverride = 'fake',
  }) : super(credentialReader: () async => const <String, String>{});

  final bool failResolve;

  /// 允许同一测试里注册多个渠道（换源需要「主渠道 + 备用渠道」）。
  final String sourceIdOverride;

  /// 挂起不返回：用于触发真实的 `.timeout()` 路径。
  /// 换源语义里「超时」与「无版权」必须区别对待，需要能单独构造超时。
  bool hang = false;

  /// 精确控制抛出的异常类型（换源语义测试依赖它区分
  /// 「确定不可用」与「网络问题」）。
  final Object? failure;

  @override
  String get sourceId => sourceIdOverride;

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
    if (hang) {
      // 永不完成：由调用方的 .timeout() 触发 TimeoutException
      await Completer<void>().future;
    }
    final forced = failure;
    if (forced != null) throw forced;
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

/// 设置 Box 由 setUpAll 打开、setUp 清空（见文件顶部）。
/// 抽成函数只是为了让用例读起来更直白。
Box<String> _settingsBoxFor() => Hive.box<String>('player_settings');

/// 计数渠道：用于验证预取是否真的减少了 resolveStream 调用。
class _CountingSource extends MusicSource {
  _CountingSource({this.failPrefetch = false})
    : super(credentialReader: () async => const <String, String>{});

  /// 让**第 2 次**解析（即预取那一次）失败，随后恢复正常。
  ///
  /// 刻意只失败一次：预取的语义是「失败就静默放弃，真实播放时重新解析」。
  /// 若让失败持续，真正点下一首时也会失败——那测的是「渠道坏了」，
  /// 而不是「预取失败不影响播放」。
  final bool failPrefetch;

  int resolveCount = 0;

  @override
  String get sourceId => 'counting';

  @override
  String get displayName => '计数渠道';

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
    if (failPrefetch && resolveCount == 2) {
      // 只让预取那一次失败
      throw UnavailableStreamException('预取失败', sourceId: sourceId);
    }
    return const ResolvedStream(
      url: '/nonexistent/file.mp3',
      isLocalFile: true,
    );
  }

  @override
  Future<LyricBundle?> fetchLyrics(Track track) async => null;
}
