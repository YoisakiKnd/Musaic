import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../../core/logging/app_logger.dart';
import '../../core/di/app_providers.dart';
import '../../core/error/source_exception.dart';
import '../../core/model/track.dart';
import '../../core/model/work_grouping.dart';
import '../../core/source/music_source.dart' show ResolvedStream;
import '../../core/network/network_config.dart';
import '../../core/network/network_status.dart';
import '../../core/theme/app_tokens.dart';
import '../settings/settings_providers.dart';
import '../../app/lifecycle/app_lifecycle.dart';
import 'audio_handler.dart';
import 'data/resume_repository.dart';
import 'domain/crossfade.dart';
import 'domain/queue_logic.dart';
import 'domain/stream_prefetcher.dart';

/// 播放状态（前端文档 §6.2）。
class PlayerState {
  const PlayerState({
    this.queue = const <Track>[],
    this.currentIndex = -1,
    this.playing = false,
    this.loading = false,
    this.position = Duration.zero,
    this.buffered = Duration.zero,
    this.duration,
    this.mode = PlayMode.sequential,
    this.shuffleOn = false,
    this.speed = 1.0,
    this.sleepTimerEndsAt,
    this.sleepSongsRemaining,
    this.error,
    this.notice,
  });

  final List<Track> queue;
  final int currentIndex;

  /// 当前曲目；队列为空或下标越界时为 null。
  Track? get current =>
      currentIndex >= 0 && currentIndex < queue.length
          ? queue[currentIndex]
          : null;

  final bool playing;
  final bool loading;
  final Duration position;
  final Duration buffered;
  final Duration? duration;

  final PlayMode mode;
  final bool shuffleOn;

  /// 倍速播放（0.75 ~ 2.0；平台不支持时保持 1.0）。
  final double speed;

  /// 定时关闭时间点；null 表示未启用。
  final DateTime? sleepTimerEndsAt;

  /// 「剩余 N 首后停止」计数（与倒计时二选一）。
  final int? sleepSongsRemaining;

  final String? error;

  /// 一次性播放提示（换源「网易云不可用，已切换到 QQ 音乐」、
  /// 「仅能试听片段」等）。
  ///
  /// 放在 state 而非 notifier 私有字段：UI 需要 `ref.listen` 到它才能弹提示，
  /// 私有字段无法被响应式观察到。消费后由 UI 调用 [clearNotice]。
  final String? notice;

  bool get hasQueue => queue.isNotEmpty;

  PlayerState copyWith({
    Object? queue = _unset,
    int? currentIndex,
    bool? playing,
    bool? loading,
    Duration? position,
    Duration? buffered,
    Object? duration = _unset,
    PlayMode? mode,
    bool? shuffleOn,
    double? speed,
    Object? sleepTimerEndsAt = _unset,
    Object? sleepSongsRemaining = _unset,
    Object? error = _unset,
    Object? notice = _unset,
  }) {
    return PlayerState(
      queue: identical(queue, _unset) ? this.queue : queue! as List<Track>,
      currentIndex: currentIndex ?? this.currentIndex,
      playing: playing ?? this.playing,
      loading: loading ?? this.loading,
      position: position ?? this.position,
      buffered: buffered ?? this.buffered,
      duration:
          identical(duration, _unset) ? this.duration : duration as Duration?,
      mode: mode ?? this.mode,
      shuffleOn: shuffleOn ?? this.shuffleOn,
      speed: speed ?? this.speed,
      sleepTimerEndsAt:
          identical(sleepTimerEndsAt, _unset)
              ? this.sleepTimerEndsAt
              : sleepTimerEndsAt as DateTime?,
      sleepSongsRemaining:
          identical(sleepSongsRemaining, _unset)
              ? this.sleepSongsRemaining
              : sleepSongsRemaining as int?,
      error: identical(error, _unset) ? this.error : error as String?,
      notice: identical(notice, _unset) ? this.notice : notice as String?,
    );
  }

  static const Object _unset = Object();
}

/// 播放状态管理（Master Plan §3.3 播放流 / §7）。
///
/// 职责：队列与模式（纯逻辑见 [QueueLogic]）、实时解析播放地址、
/// 驱动 audio_handler 广播、进度节流刷新、定时关闭。
/// 每次播放经渠道 resolveStream 实时解析，不缓存过期 URL。
class PlayerNotifier extends Notifier<PlayerState> {
  late MusaicAudioHandler _handler;
  StreamSubscription<ja.PlayerState>? _stateSub;
  StreamSubscription<ja.PlaybackEvent>? _eventSub;
  Timer? _positionTimer;
  Duration _positionTimerPeriod = AppTokens.positionThrottle;
  Timer? _sleepTimer;
  bool _autoAdvancing = false;
  int _loadSeq = 0; // 加载序号：过期请求的状态更新一律丢弃
  final Random _random = Random();

  /// 应用不可见（息屏/后台/桌面最小化）时降级标志（功耗计划 PW-03）。
  bool _uiDegraded = false;

  /// 后台播放时的进度采样周期：仅维持断点快照（功耗计划 PW-03）。
  static const Duration _backgroundPositionThrottle = Duration(seconds: 1);

  /// 断点续播仓库与写入节流时间戳。
  ResumeRepository? _resume;
  DateTime _lastResumeWrite = DateTime.fromMillisecondsSinceEpoch(0);

  /// 随机模式洗牌序列（shuffleOn=false 时忽略）。
  List<int>? _shuffleOrder;

  /// 淡入淡出（单播放器，设置项「淡入淡出」）：本曲开头是否需要渐强。
  ///
  /// 只有「自然播完 → 自动推进」来的下一首才渐强；用户手动点歌要立即出声。
  bool _fadeInActive = false;

  /// 是否处于渐弱/渐强窗口。窗口内即使在后台也保持 100ms 采样——
  /// 1Hz 的后台采样会让音量阶梯式跳变。
  bool _inFadeWindow = false;

  /// 最近一次写给播放器的音量（避免每次采样都调用平台通道）。
  double? _appliedVolume;

  /// 播放器是否已成功装载当前曲目。
  ///
  /// 加载失败、播放中途出错、队列清空后为 false：此时单纯 `play()`
  /// 不会出声，[toggle] 必须改为从断点重新加载。
  bool _sourceLoaded = false;

  /// 播放中途出错（签名地址过期、网络抖动）的自动恢复计数，按曲目统计。
  String? _recoveryTrackKey;
  int _recoveryAttempts = 0;
  static const int _maxRecoveryAttempts = 2;

  /// 因网络问题停下的时间点；网络恢复时据此决定是否自动续播。
  DateTime? _networkFailureAt;

  /// 网络恢复后自动续播的时效：断网太久，用户多半已经不在听了。
  static const Duration _networkResumeWindow = Duration(minutes: 5);

  /// 播放地址预取器（P2：降低「点歌到出声」延迟）。
  ///
  /// 在切歌成功、且当前曲目剩余时间充足时预取下一首的解析结果，
  /// 使用户点「下一首」时跳过网络解析这一步。
  late final StreamPrefetcher _prefetcher;

  /// 连续自动跳过的次数。
  ///
  /// 用于防止「整队列全部不可播」时无限跳歌：跳完一轮仍失败就停下报错，
  /// 而不是把用户整个队列静默刷完（那会让用户完全不知道发生了什么）。
  int _consecutiveSkips = 0;

  /// 一轮最多连续跳过多少首。超过则停止并报错。
  static const int _maxConsecutiveSkips = 5;

  /// 跨渠道换源候选：曲目 key → 同作品在其它渠道的记录（D7）。
  ///
  /// 在 [playQueue] 时**一次性**算好（纯内存分组，零额外请求），
  /// 播放失败时直接查表，避免在失败路径上再做网络或计算。
  Map<String, List<Track>> _alternatives = const <String, List<Track>>{};

  @override
  PlayerState build() {
    _handler = ref.watch(audioHandlerProvider);
    _resume = ref.read(resumeRepositoryProvider);
    _handler.onPlay = resume;
    _handler.onNext = _onSystemSkipToNext;
    _handler.onPrevious = _onSystemSkipToPrevious;
    _handler.onSkipToQueueIndex = playAt;
    _handler.onRemoveQueueTrack = (key) {
      final index = state.queue.indexWhere((t) => t.key == key);
      if (index >= 0) return removeFromQueue(index);
      return Future.value();
    };

    _prefetcher = StreamPrefetcher(
      resolve: (track) async {
        try {
          return await _prefetchResolve(track);
        } catch (_) {
          return null; // 预取失败静默
        }
      },
    );

    _stateSub = _handler.player.playerStateStream.listen(_onPlayerStateChanged);
    // 播放中途的错误（断流、签名地址过期）只出现在事件流的 error 通道，
    // playerStateStream 只会把它表现为 idle——而 idle 被刻意忽略，
    // 不监听这里会让界面卡在「播放中」却没有声音。
    _eventSub = _handler.player.playbackEventStream.listen(
      (_) {},
      onError: _onPlaybackError,
    );

    // 功耗计划 PW-03：应用不可见时进度采样降为 1Hz（仅供断点快照），
    // 回前台恢复 100ms UI 预算并立即校正一次进度。
    // 直连 [AppUiVisibility]：经 Provider.listen 会把生命周期变化
    // 升级为 Notifier 重建，播放状态会被无谓重置。
    // 断网导致的播放失败：网络恢复时自动从断点续播（地铁/电梯场景）
    ref.listen<AsyncValue<bool>>(networkOnlineProvider, (previous, next) {
      if (previous?.valueOrNull == false && next.valueOrNull == true) {
        _onNetworkRestored();
      }
    });

    _onVisibilityChanged = _handleVisibilityChanged;
    AppUiVisibility.addListener(_onVisibilityChanged!);

    ref.onDispose(() {
      _disposed = true;
      _stateSub?.cancel();
      _eventSub?.cancel();
      _positionTimer?.cancel();
      _positionTimer = null;
      _sleepTimer?.cancel();
      if (_onVisibilityChanged != null) {
        AppUiVisibility.removeListener(_onVisibilityChanged!);
        _onVisibilityChanged = null;
      }
    });

    // 恢复用户上次的音量 / 倍速 / 播放模式（播放器该记住的东西）。
    //
    // 放在 build() 末尾而非异步初始化：这些值必须**在任何播放开始前**
    // 生效，否则首曲会用默认音量/倍速播出去（夜间戴耳机时很突兀）。
    final settings = ref.read(appSettingsRepositoryProvider);
    final restored = PlayerState(
      speed: settings.playbackSpeed,
      mode: settings.playMode,
      shuffleOn: settings.shuffleOn,
    );
    final player = _handler.player;
    player.setVolume(settings.volume);
    player.setSpeed(restored.speed);
    if (restored.shuffleOn) {
      _shuffleOrder = QueueLogic.shuffledOrder(0, random: _random);
    }

    return restored;
  }

  void Function(bool degraded)? _onVisibilityChanged;

  void _handleVisibilityChanged(bool degraded) {
    _uiDegraded = degraded;
    if (!degraded) _tickPosition();
    _syncPositionTimer();
  }

  /// 位置轮询定时器生命周期（功耗计划 PW-01 / B21）：
  /// 仅在播放/加载期间存活，任何状态变更后即时同步；
  /// 暂停与空闲状态零周期唤醒。
  @override
  set state(PlayerState value) {
    super.state = value;
    _syncPositionTimer();
  }

  void _syncPositionTimer() {
    final shouldRun = state.playing || state.loading;
    if (!shouldRun) {
      _positionTimer?.cancel();
      _positionTimer = null;
      return;
    }
    final period =
        _uiDegraded && !_inFadeWindow
            ? _backgroundPositionThrottle
            : AppTokens.positionThrottle;
    if (_positionTimer != null && _positionTimerPeriod == period) return;
    _positionTimer?.cancel();
    _positionTimerPeriod = period;
    _positionTimer = Timer.periodic(period, (_) => _tickPosition());
  }

  // ---------- 仅供测试观察（PW-04 空闲纪律断言） ----------

  /// 当前是否处于渐弱/渐强窗口（供测试断言）。
  @visibleForTesting
  bool get debugInFadeWindow => _inFadeWindow;

  /// 最近一次写给播放器的音量（供测试断言）。
  @visibleForTesting
  double? get debugAppliedVolume => _appliedVolume;

  /// 驱动一次淡入淡出计算（供测试断言，绕过定时器）。
  @visibleForTesting
  void debugApplyFade(Duration position, Duration? duration) =>
      _applyFade(position, duration);

  /// 模拟播放中途出错（供测试驱动恢复路径）。
  @visibleForTesting
  void debugPlaybackError(Object error) => _onPlaybackError(error);

  /// 位置轮询定时器是否存活。
  @visibleForTesting
  bool get debugIsPositionTimerActive => _positionTimer != null;

  /// _tickPosition 实际执行次数（排除降级跳过）。
  @visibleForTesting
  int debugPositionTicks = 0;

  // ---------- 仅供测试驱动（P0 回归守护） ----------

  /// 自动推进重入闸门当前值。
  ///
  /// 该标志泄漏为 true 会让播放态同步与自动切歌永久失效，
  /// 必须可被测试直接断言。
  @visibleForTesting
  bool get debugAutoAdvancing => _autoAdvancing;

  @visibleForTesting
  set debugAutoAdvancing(bool value) => _autoAdvancing = value;

  /// 当前洗牌序列（长度必须恒等于队列长度）。
  @visibleForTesting
  List<int>? get debugShuffleOrder => _shuffleOrder;

  /// 直接注入队列/模式，绕过真实网络解析。
  @visibleForTesting
  void debugSeedState({
    required List<Track> queue,
    int currentIndex = 0,
    PlayMode mode = PlayMode.sequential,
    bool shuffleOn = false,
    int? sleepSongsRemaining,
  }) {
    state = state.copyWith(
      queue: List<Track>.unmodifiable(queue),
      currentIndex: currentIndex,
      mode: mode,
      shuffleOn: shuffleOn,
      sleepSongsRemaining: sleepSongsRemaining,
    );
    _shuffleOrder =
        shuffleOn ? List<int>.generate(queue.length, (i) => i) : null;
  }

  /// 驱动「自然播完」推进路径。
  @visibleForTesting
  Future<void> debugAdvanceOnComplete() => _advanceOnComplete();

  /// 预取器状态（仅供测试断言「队列替换是否作废旧预取」）。
  @visibleForTesting
  bool get debugHasFreshPrefetch => _prefetcher.hasEntry;

  /// 驱动加载路径（用于越界守卫断言）。
  @visibleForTesting
  Future<void> debugLoadAndPlay(int index) => _loadAndPlay(index);

  // ---------- 对外操作 ----------

  /// 用一份队列开始播放（Master Plan §3.3：UI 点歌 → playQueue）。
  ///
  /// [initialPosition] 用于断点续播：直接从该位置装载，而不是先从头播
  /// 再 seek（那样开头会漏出一小段声音）。
  ///
  /// [alternativesPool]：不进队列、但可作为跨渠道换源候选的曲目
  /// （如搜索结果页里同一首歌的其它渠道版本）。
  Future<void> playQueue(
    List<Track> tracks, {
    int startIndex = 0,
    Duration? initialPosition,
    List<Track> alternativesPool = const <Track>[],
  }) async {
    if (tracks.isEmpty) return;
    final index = startIndex.clamp(0, tracks.length - 1);
    if (_shuffleOrder == null ||
        tracks.length != state.queue.length ||
        !_sameQueue(tracks)) {
      _shuffleOrder = QueueLogic.shuffledOrder(tracks.length, random: _random);
      _moveCurrentToShuffleHead(currentIndex: index);
    }
    // 换源候选只在整队列变更时重算：同一队列内切歌无需重复分组
    _alternatives = buildAlternatives(
      _dedupeByKey([...tracks, ...alternativesPool]),
    );
    // 队列换了，旧的预取结果（针对旧队列的下一首）已无意义
    _prefetcher.invalidate();
    state = state.copyWith(
      queue: List<Track>.unmodifiable(tracks),
      currentIndex: index,
      error: null,
    );
    _syncSystemQueue();
    await _loadAndPlay(index, initialPosition: initialPosition);
  }

  /// 随机播放整个列表：开启随机模式，从随机一首开始。
  Future<void> shufflePlay(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    if (!state.shuffleOn) {
      state = state.copyWith(shuffleOn: true);
      unawaited(ref.read(appSettingsRepositoryProvider).setShuffleOn(true));
    }
    _shuffleOrder = null; // 同一列表再次随机播放也要重新洗牌
    await playQueue(tracks, startIndex: _random.nextInt(tracks.length));
  }

  /// 立即播放单曲，并**保留当前队列**（搜索结果点歌的语义）。
  ///
  /// 搜索结果此前走 [playQueue]：整页结果（往往是同一首歌的几十个版本）
  /// 替换掉用户的队列，播完一首会接着播同名的其它版本。现在只把这首插到
  /// 当前曲之后并立即播放。
  ///
  /// [alternativesPool] 是这首歌所在的结果列表，用于计算跨渠道换源候选
  /// （D7）——不进队列，但无版权时仍能切到其它渠道的同一首。
  Future<void> playNow(
    Track track, {
    List<Track> alternativesPool = const <Track>[],
  }) async {
    if (!state.hasQueue) {
      await playQueue([track], alternativesPool: alternativesPool);
      return;
    }
    _mergeAlternatives(track, alternativesPool);
    final result = QueueLogic.insertAsNext(
      queue: state.queue,
      track: track,
      currentIndex: state.currentIndex,
    );
    state = state.copyWith(
      queue: List<Track>.unmodifiable(result.queue),
      currentIndex: result.currentIndex,
    );
    if (state.shuffleOn) _reshuffleKeepingCurrent();
    final index = state.queue.indexWhere((t) => t.key == track.key);
    _syncSystemQueue();
    await _loadAndPlay(index);
  }

  void _mergeAlternatives(Track track, List<Track> pool) {
    if (pool.isEmpty) return;
    final found = buildAlternatives(_dedupeByKey([track, ...pool]))[track.key];
    if (found == null) return;
    _alternatives = {..._alternatives, track.key: found};
  }

  /// 追加到队尾。
  void addToQueue(Track track) {
    final queue = [...state.queue, track];
    if (state.shuffleOn) {
      _shuffleOrder = QueueLogic.shuffledOrder(queue.length, random: _random);
      _moveCurrentToShuffleHead(currentIndex: state.currentIndex);
    }
    state = state.copyWith(queue: List<Track>.unmodifiable(queue));
    _syncSystemQueue();
  }

  /// 插入到「下一首播放」位置（当前曲之后）。
  /// 曲目已在队列中则先移除再插入（去重移动语义）；空队列时直接开播。
  Future<void> insertNext(Track track) async {
    final result = QueueLogic.insertAsNext(
      queue: state.queue,
      track: track,
      currentIndex: state.currentIndex,
    );
    state = state.copyWith(
      queue: List<Track>.unmodifiable(result.queue),
      currentIndex: result.currentIndex,
    );
    if (state.shuffleOn) _reshuffleKeepingCurrent();
    _syncSystemQueue();
    if (result.currentIndex < 0 && result.queue.isNotEmpty) {
      await playAt(0); // 原本无队列：直接开播这支
    }
  }

  /// 清空队列：仅保留当前曲（Apple Music 语义）。
  void clearQueue() {
    final current = state.current;
    if (current == null) return;
    state = state.copyWith(
      queue: List<Track>.unmodifiable([current]),
      currentIndex: 0,
    );
    _shuffleOrder = null;
    _syncSystemQueue();
  }

  /// 队列内移动（拖拽排序）。当前曲目跟随自身位置调整。
  void moveInQueue(int oldIndex, int newIndex) {
    final result = QueueLogic.moveTrack(
      queue: state.queue,
      oldIndex: oldIndex,
      newIndex: newIndex,
      currentIndex: state.currentIndex,
    );
    state = state.copyWith(
      queue: List<Track>.unmodifiable(result.queue),
      currentIndex: result.currentIndex,
    );
    if (state.shuffleOn) _reshuffleKeepingCurrent();
    _syncSystemQueue();
  }

  /// 移除队列项。移除的是当前曲时自动播放顺延到位的下一曲；
  /// 队列清空则停止播放。
  Future<void> removeFromQueue(int index) async {
    final result = QueueLogic.removeTrackAt(
      queue: state.queue,
      index: index,
      currentIndex: state.currentIndex,
    );
    if (identical(result.queue, state.queue)) return; // 越界，无变更

    if (result.queue.isEmpty) {
      _shuffleOrder = null;
      _sleepTimer?.cancel();
      _sourceLoaded = false;
      await _resume?.clear();
      await _handler.stop();
      state = state.copyWith(
        queue: const <Track>[],
        currentIndex: -1,
        playing: false,
        loading: false,
        position: Duration.zero,
        sleepTimerEndsAt: null,
        sleepSongsRemaining: null,
      );
      _syncSystemQueue();
      return;
    }

    state = state.copyWith(queue: List<Track>.unmodifiable(result.queue));
    // 洗牌序列长度必须始终等于队列长度，否则 nextIndex 会返回越界下标
    // （P0：shuffle 下移除当前曲 → RangeError 崩溃）。
    // 因此无论是否移除当前曲，只要洗牌开启就重建序列。
    if (state.shuffleOn) _reshuffleKeepingCurrent();
    if (result.removedCurrent) {
      await _loadAndPlay(result.currentIndex);
    } else {
      state = state.copyWith(currentIndex: result.currentIndex);
    }
    _syncSystemQueue();
  }

  Future<void> toggle() async {
    final player = _handler.player;
    if (player.playing) {
      await player.pause();
      state = state.copyWith(playing: false);
    } else {
      await resume();
    }
  }

  /// 继续播放（播放键 / 通知栏 / 耳机）。
  ///
  /// 当前曲没有装载成功（加载失败 / 播放中途断流后）时，`play()` 不会出声，
  /// 用户看到的是「点了播放没反应」——此时改为从断点重新加载。
  Future<void> resume() async {
    if (!state.hasQueue || state.current == null) return;
    if (!_sourceLoaded) {
      await _loadAndPlay(
        state.currentIndex,
        initialPosition: state.position > Duration.zero ? state.position : null,
      );
      return;
    }
    await _handler.player.play();
    state = state.copyWith(playing: true, error: null);
  }

  /// 上一首：超 3 秒先回开头（Mei 行为对齐，见 QueueLogic）。
  Future<void> previous() async {
    if (!state.hasQueue) return;
    if (QueueLogic.shouldRestartOnPrevious(position: state.position)) {
      await seekTo(Duration.zero);
      return;
    }
    final advance = QueueLogic.previousIndex(
      currentIndex: state.currentIndex,
      length: state.queue.length,
      mode: state.mode,
      shuffleOn: state.shuffleOn,
      shuffleOrder: _shuffleOrder,
    );
    if (advance == null) return;
    await _loadAndPlay(advance.index);
  }

  Future<void> next() => _next(fadeIn: false);

  /// [fadeIn]：仅「自然播完 → 自动推进」为 true，新曲开头渐强。
  Future<void> _next({required bool fadeIn}) async {
    if (!state.hasQueue) return;
    final advance = QueueLogic.nextIndex(
      currentIndex: state.currentIndex,
      length: state.queue.length,
      mode: state.mode,
      shuffleOn: state.shuffleOn,
      shuffleOrder: _shuffleOrder,
    );
    if (advance == null) {
      // 队列尽头：必须暂停 just_audio，让系统会话/通知同步为暂停态。
      // 否则通知栏停留在过期的 PLAYING，前台服务也一直挂着（EMU 实测）。
      //
      // 同时复位 _autoAdvancing：用户在「自然播完」的异步窗口内手动点
      // 下一首时也会走到这里，若不复位则该闸门永久关闭（P0 回归）。
      _autoAdvancing = false;
      await _handler.pause();
      state = state.copyWith(
        playing: false,
        position: state.duration ?? state.position,
      );
      return;
    }
    if (advance.wrapped && state.shuffleOn) {
      _shuffleOrder = QueueLogic.shuffledOrder(
        state.queue.length,
        random: _random,
      );
      _moveCurrentToShuffleHead(currentIndex: state.currentIndex);
    }
    await _loadAndPlay(advance.index, fadeIn: fadeIn);
  }

  Future<void> playAt(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    await _loadAndPlay(index);
  }

  Future<void> seekTo(Duration position) async {
    await _handler.seek(position);
    state = state.copyWith(position: position);
    // 拖进/拖出曲末渐弱窗口时立即修正音量，不等下一次采样
    if (state.playing) _applyFade(position, _handler.player.duration);
  }

  void setMode(PlayMode mode) {
    state = state.copyWith(mode: mode);
    unawaited(ref.read(appSettingsRepositoryProvider).setPlayMode(mode));
  }

  void toggleShuffle() {
    final shuffleOn = !state.shuffleOn;
    if (shuffleOn) {
      _shuffleOrder = QueueLogic.shuffledOrder(
        state.queue.length,
        random: _random,
      );
      _moveCurrentToShuffleHead(currentIndex: state.currentIndex);
    }
    state = state.copyWith(shuffleOn: shuffleOn);
    unawaited(ref.read(appSettingsRepositoryProvider).setShuffleOn(shuffleOn));
  }

  /// 定时关闭（倒计时）：传 null 取消（对齐 Mei 的定时播放）。
  /// 与「N 首后停止」互斥，设置一种会自动清除另一种。
  void setSleepTimer(Duration? remaining) {
    _sleepTimer?.cancel();
    if (remaining == null) {
      state = state.copyWith(sleepTimerEndsAt: null);
      return;
    }
    state = state.copyWith(
      sleepTimerEndsAt: DateTime.now().add(remaining),
      sleepSongsRemaining: null,
    );
    _sleepTimer = Timer(remaining, () async {
      try {
        await _handler.pause();
      } finally {
        state = state.copyWith(playing: false, sleepTimerEndsAt: null);
      }
    });
  }

  /// 「播完 N 首后停止」；N<=0 视为取消。播完当前曲=1。
  void setSleepAfterSongs(int n) {
    _sleepTimer?.cancel();
    state = state.copyWith(
      sleepTimerEndsAt: null,
      sleepSongsRemaining: n <= 0 ? null : n,
    );
  }

  /// 取消全部定时策略。
  void clearSleep() {
    _sleepTimer?.cancel();
    state = state.copyWith(sleepTimerEndsAt: null, sleepSongsRemaining: null);
  }

  /// 倍速播放；平台不支持时置错误提示并保持原速。
  Future<void> setSpeed(double value) async {
    final clamped = value.clamp(minPlaybackSpeed, maxPlaybackSpeed);
    try {
      await _handler.player.setSpeed(clamped);
      state = state.copyWith(speed: clamped, error: null);
      // 持久化：倍速常被长期固定（播客/有声书），不记住会每次重设
      unawaited(
        ref.read(appSettingsRepositoryProvider).setPlaybackSpeed(clamped),
      );
    } catch (_) {
      state = state.copyWith(error: '当前平台不支持倍速播放');
    }
  }

  /// 设置音量并持久化。
  ///
  /// 音量此前只存在播放页的局部 `_volume` 里，退出应用即丢失。
  Future<void> setVolume(double value) async {
    final clamped = value.clamp(0.0, 1.0);
    await _handler.player.setVolume(clamped);
    // 淡入淡出窗口内由下一次采样按新基准重新计算
    _appliedVolume = null;
    unawaited(ref.read(appSettingsRepositoryProvider).setVolume(clamped));
  }

  void clearError() => state = state.copyWith(error: null);

  /// 重试当前曲目：清空错误后重新解析并播放。
  ///
  /// 与 [playAt] 的区别在于必须绕过「下标越界即返回」的短路——
  /// 当前曲被移除后 [currentIndex] 可能已越界，此时回到队首重试。
  Future<void> retry() async {
    if (!state.hasQueue) {
      clearError();
      return;
    }
    final index =
        state.currentIndex >= 0 && state.currentIndex < state.queue.length
            ? state.currentIndex
            : 0;
    state = state.copyWith(error: null);
    await _loadAndPlay(index);
  }

  Future<void> _onSystemSkipToNext() => next();

  Future<void> _onSystemSkipToPrevious() => previous();

  // ---------- 内部实现 ----------

  static List<Track> _dedupeByKey(List<Track> tracks) {
    final seen = <String>{};
    return [
      for (final t in tracks)
        if (seen.add(t.key)) t,
    ];
  }

  bool _sameQueue(List<Track> tracks) {
    if (tracks.length != state.queue.length) return false;
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i].key != state.queue[i].key) return false;
    }
    return true;
  }

  void _moveCurrentToShuffleHead({required int currentIndex}) {
    final order = _shuffleOrder;
    if (order == null || currentIndex < 0 || currentIndex >= order.length) {
      return;
    }
    order.remove(currentIndex);
    order.insert(0, currentIndex);
  }

  /// 加载并播放队列中的第 [index] 首。
  ///
  /// - [fadeIn]：开头渐强（仅自然推进时）；
  /// - [initialPosition]：从该位置开始（断点续播 / 中途出错恢复）；
  /// - [recovering]：播放中途出错后的恢复加载。恢复失败**不自动跳歌**——
  ///   用户正在听这首，静默跳走比停下报错更让人困惑。
  Future<void> _loadAndPlay(
    int index, {
    bool fadeIn = false,
    Duration? initialPosition,
    bool recovering = false,
  }) async {
    // 越界守卫：洗牌序列/队列在并发变更下可能短暂失配，
    // 此处是最后一道防线（release 下 assert 被剥离，必须显式判断）。
    if (index < 0 || index >= state.queue.length) return;
    final seq = ++_loadSeq;
    final track = state.queue[index];
    _sourceLoaded = false;
    _fadeInActive = false;
    state = state.copyWith(
      currentIndex: index,
      loading: true,
      position: initialPosition ?? Duration.zero,
      buffered: Duration.zero,
      duration: track.duration,
      error: null,
    );
    _autoAdvancing = false;

    try {
      // 跨渠道换源（D7）：先试当前渠道，仅在「确定不可用」时前进到下一渠道。
      //
      // 错误语义是设计的一部分，不是实现细节：
      // - UnavailableStreamException（无版权/地区限制/需会员）→ 换源有意义
      // - AuthRequiredException（未登录）→ 换源有意义（换匿名可用渠道）
      // - NetworkSourceException（断网/超时）→ **不换源**，否则用户断网时
      //   播放器会在四个渠道间空转数十秒，最后报一个与真实原因无关的错误
      final resolved = await _resolveWithFallback(track, seq);
      if (resolved == null) return; // 已被更新的加载请求取代

      // 换源成功时 track 已更新为实际播放的那条记录，
      // 后续元数据/历史/断点都必须用新记录，否则显示与实听不一致。
      final effectiveTrack = _lastResolvedTrack ?? track;
      if (seq != _loadSeq) return;
      if (kDebugMode) {
        AppLog.debug(
          'MusaicPlayer stream: source=${effectiveTrack.sourceId} '
          '(local=${resolved.isLocalFile})',
        );
      }

      final player = _handler.player;
      final Duration? loadedDuration;
      if (resolved.isLocalFile) {
        loadedDuration = await player
            .setFilePath(resolved.url, initialPosition: initialPosition)
            .timeout(const Duration(seconds: 25));
      } else {
        loadedDuration = await player
            .setUrl(
              resolved.url,
              headers: resolved.headers ?? const <String, String>{},
              initialPosition: initialPosition,
            )
            .timeout(const Duration(seconds: 25));
      }
      if (seq != _loadSeq) return;
      _sourceLoaded = true;
      _networkFailureAt = null;
      // 并非所有渠道都会标注试听片段：实际音频远短于曲目时长时同样提示
      if (!resolved.isPreview &&
          looksLikePreviewClip(
            expected: effectiveTrack.duration,
            actual: loadedDuration,
          )) {
        _notifyPreviewOnly(effectiveTrack);
      }
      _handler.updateNowPlaying(
        trackToMediaItem(effectiveTrack),
        queueIndex: index,
      );
      // 倍速跨曲目保持（部分平台 load 后重置）
      if (state.speed != 1.0) {
        try {
          await player.setSpeed(state.speed);
        } catch (_) {}
      }
      // 起始音量：自然推进且开启淡入淡出时从 0 渐强，否则直接用设定音量
      // （上一首可能停在渐弱后的低音量，手动切歌必须立即恢复）。
      _fadeInActive = fadeIn && _fadeDuration > Duration.zero;
      _appliedVolume = null;
      _setPlayerVolume(_fadeInActive ? 0.0 : _baseVolume);
      await player.play();
      if (seq != _loadSeq) return;
      state = state.copyWith(loading: false, playing: true);
      _consecutiveSkips = 0; // 播放成功即重置连续跳过计数
      // 播放稳定后预取下一首（P2）
      _prefetchNext(index);

      // 记录最近播放与断点快照起点（本地优先存储，失败静默）
      unawaited(_recordHistory(effectiveTrack));
      _persistResume(force: true);
    } on SourceException catch (e) {
      if (seq != _loadSeq) return;
      AppLog.debug('MusaicPlayer SourceException: ${e.message}');
      state = state.copyWith(loading: false, playing: false, error: e.message);
      // 网络问题换下一首同样会失败：保留错误等用户重试，
      // 而不是在断网时把整个队列逐首刷过去。
      if (e is NetworkSourceException) {
        _networkFailureAt = DateTime.now();
      } else if (!recovering) {
        unawaited(_skipAfterFailure(index));
      }
    } on TimeoutException {
      if (seq != _loadSeq) return;
      AppLog.debug('MusaicPlayer 加载音频超时');
      _networkFailureAt = DateTime.now();
      state = state.copyWith(
        loading: false,
        playing: false,
        error: '加载超时，请检查网络后重试',
      );
    } catch (e, st) {
      if (seq != _loadSeq) return;
      AppLog.debug('MusaicPlayer 播放异常: $e');
      AppLog.debug(
        'MusaicPlayer 堆栈首行: '
        '${st.toString().split('\n').take(4).join(' | ')}',
      );
      state = state.copyWith(
        loading: false,
        playing: false,
        error: '播放失败，请稍后重试',
      );
      if (!recovering) unawaited(_skipAfterFailure(index));
    }
  }

  void _onNetworkRestored() {
    final failedAt = _networkFailureAt;
    if (failedAt == null || _disposed) return;
    _networkFailureAt = null;
    if (DateTime.now().difference(failedAt) > _networkResumeWindow) return;
    if (state.playing || state.loading || state.current == null) return;
    AppLog.debug('MusaicPlayer 网络已恢复，自动续播');
    _recoveryAttempts = 0;
    unawaited(resume());
  }

  /// 播放中途出错：重新解析地址并从断点续播，每首最多 [_maxRecoveryAttempts] 次。
  ///
  /// 典型场景：暂停很久后继续（签名地址已过期）、地铁里短暂断网。
  void _onPlaybackError(Object error, [StackTrace? _]) {
    // 加载阶段的错误由 _loadAndPlay 的 catch 处理，这里只管「已开始播放后」
    if (_disposed || state.loading || !_sourceLoaded) return;
    final track = state.current;
    if (track == null) return;
    _sourceLoaded = false;
    AppLog.debug('MusaicPlayer 播放中断: $error');
    if (_recoveryTrackKey != track.key) {
      _recoveryTrackKey = track.key;
      _recoveryAttempts = 0;
    }
    if (_recoveryAttempts >= _maxRecoveryAttempts) {
      _networkFailureAt = DateTime.now();
      state = state.copyWith(playing: false, error: '播放中断，请检查网络后重试');
      _persistResume(force: true);
      return;
    }
    _recoveryAttempts++;
    unawaited(
      _loadAndPlay(
        state.currentIndex,
        initialPosition: state.position,
        recovering: true,
      ),
    );
  }

  /// 最近一次成功解析所用的曲目（换源后与队列里的原始记录不同）。
  Track? _lastResolvedTrack;

  /// 解析播放地址，必要时按换源候选依次尝试（D7）。
  ///
  /// 返回 null 表示本次加载已被更新的请求取代（调用方应直接 return）。
  /// 全部候选都失败时抛出**最后一次**的异常——它最能反映真实原因。
  ///
  /// 试听片段（[ResolvedStream.isPreview]）不算成功：先记下来继续找其它
  /// 渠道的完整版本，都找不到时才退回播放片段并提示用户——否则用户听到
  /// 30 秒就「莫名其妙切歌了」。
  Future<ResolvedStream?> _resolveWithFallback(Track track, int seq) async {
    // 预取命中：跳过网络解析（这是「点歌到出声」里最慢的一段）。
    // take() 是一次性的——签名 URL 不复用，避免用到已失效地址。
    final prefetched = _prefetcher.take(track);
    if (prefetched != null) {
      if (seq != _loadSeq) return null;
      _lastResolvedTrack = track;
      if (prefetched.isPreview) _notifyPreviewOnly(track);
      if (kDebugMode) AppLog.debug('MusaicPlayer 命中预取: ${track.key}');
      return prefetched;
    }

    final registry = ref.read(sourceRegistryProvider);
    final candidates = <Track>[
      track,
      ...orderFallbackCandidates(
        alternatives: _alternatives[track.key] ?? const <Track>[],
        failedSourceId: track.sourceId,
      ),
    ];

    Object? lastError;
    (Track, ResolvedStream)? preview;
    final triedSources = <String>[];
    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      final source = registry.resolve(candidate.sourceId);
      if (source == null) {
        lastError = NetworkSourceException(
          '「${candidate.sourceId}」渠道不可用',
          sourceId: candidate.sourceId,
        );
        continue;
      }
      if (!triedSources.contains(candidate.sourceId)) {
        triedSources.add(candidate.sourceId);
      }
      try {
        final resolved = await source
            .resolveStream(candidate)
            .timeout(Duration(seconds: NetworkConfig.instance.seconds * 2));
        if (seq != _loadSeq) return null;
        if (resolved.isPreview) {
          preview ??= (candidate, resolved);
          continue; // 先找完整版本
        }
        _lastResolvedTrack = candidate;
        // 换源成功时告知用户，避免「怎么换了个版本」的困惑
        if (i > 0) {
          _notifySourceSwitched(from: track, to: candidate);
        }
        return resolved;
      } on TimeoutException {
        // 超时归入网络问题，**不换源**：断网时每个候选都会各自超时，
        // 4 个候选 × 8s 超时 = 用户干等 30 秒以上，比直接报错更糟。
        // 只有「确定不可用」才值得换源（见上方注释的错误语义）。
        if (preview != null) break;
        throw NetworkSourceException('解析播放地址超时', sourceId: candidate.sourceId);
      } on UnavailableStreamException catch (e) {
        lastError = e;
        continue; // 无版权/需会员 → 换源
      } on AuthRequiredException catch (e) {
        lastError = e;
        continue; // 未登录 → 换匿名可用渠道
      } on NetworkSourceException {
        // 断网/连接失败：换源没有意义，立即失败并保留真实原因
        if (preview != null) break;
        rethrow;
      } catch (e) {
        lastError = e;
        continue; // 渠道内部异常：值得试下一个
      }
    }

    if (preview != null) {
      final (previewTrack, stream) = preview;
      _lastResolvedTrack = previewTrack;
      _notifyPreviewOnly(previewTrack);
      return stream;
    }
    // 换过源仍失败：说明试过哪些渠道。否则界面显示的是原曲（如 QQ 音乐），
    // 错误却是最后一个候选的（如「请登录酷狗」），用户无从理解。
    if (lastError is UnavailableStreamException ||
        lastError is AuthRequiredException) {
      final reason = (lastError as SourceException).message;
      if (triedSources.length > 1) {
        throw UnavailableStreamException(
          '已尝试${triedSources.map(_sourceName).join('、')}，均无法播放：$reason',
          sourceId: track.sourceId,
          cause: lastError,
        );
      }
    }
    if (lastError != null) throw lastError;
    throw NetworkSourceException('无可用播放源', sourceId: track.sourceId);
  }

  /// 播放失败后自动跳下一首。
  ///
  /// 为什么需要：Musaic 是多渠道路由，个别曲目不可播是**常态**
  /// （版权变动、渠道限流、本地文件被删）。若失败即停，用户听一张专辑
  /// 会频繁被打断并手动点下一首。
  ///
  /// 何时**不**跳：
  /// - 队列只有一首（跳了等于没播，报错更有信息量）；
  /// - 已连续跳过 [_maxConsecutiveSkips] 首（大概率是网络/登录等系统性问题，
  ///   继续跳会把整个队列静默刷完，用户反而不知道出了什么事）；
  /// - 单曲循环模式（用户明确要求重复这一首，失败应如实报错）。
  Future<void> _skipAfterFailure(int failedIndex) async {
    if (!state.hasQueue) return;
    // 注：单曲循环与「队列只有一首」两种情况**无需在此特判**——
    // `QueueLogic.nextIndex` 在 loopOne 下返回当前下标、在 length<=1 时返回
    // null，两种情况都不会产生「跳到别处」的结果。此前写了冗余守卫，
    // 变异测试显示删掉它们测试仍全绿，即守卫无效——故移除，避免给出
    // 「这里做过特殊处理」的错觉。
    if (_consecutiveSkips >= _maxConsecutiveSkips) {
      AppLog.warning('连续 $_consecutiveSkips 首播放失败，停止自动跳过并保留错误提示');
      return;
    }

    // 用当前模式算出下一首；顺序模式到队尾即停止（不绕回）
    final advance = QueueLogic.nextIndex(
      currentIndex: failedIndex,
      length: state.queue.length,
      mode: state.mode,
      shuffleOn: state.shuffleOn,
      shuffleOrder: _shuffleOrder,
    );
    if (advance == null) return; // 队尾：保留错误提示，不再跳

    _consecutiveSkips++;
    AppLog.debug('第 $_consecutiveSkips 首连续失败，自动跳到下标 ${advance.index}');
    // 让 UI 有机会看到失败提示再跳：立刻切歌会让用户完全没察觉
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!state.hasQueue || failedIndex >= state.queue.length) return;
    await _loadAndPlay(advance.index);
  }

  /// 供预取使用的静默解析：只解析曲目**自身渠道**，不换源、不改状态。
  ///
  /// 预取发生在「当前曲还在播」时，此时不应产生任何用户可见副作用。
  /// 也不在这里换源：换源得到的是另一条记录，若当作原曲的预取结果，
  /// 播放时元数据、历史与「已切换渠道」提示都会对不上——交给真实播放
  /// 路径处理。试听片段同理不预取。
  Future<ResolvedStream?> _prefetchResolve(Track track) async {
    final source = ref.read(sourceRegistryProvider).resolve(track.sourceId);
    if (source == null) return null;
    final resolved = await source
        .resolveStream(track)
        .timeout(Duration(seconds: NetworkConfig.instance.seconds * 2));
    return resolved.isPreview ? null : resolved;
  }

  /// 淡入淡出时长（0 = 关闭）。
  Duration get _fadeDuration =>
      Duration(seconds: ref.read(crossfadeSecondsProvider));

  /// 用户设定的音量；淡入淡出只作用于相对音量，不覆盖它。
  double get _baseVolume => ref.read(appSettingsRepositoryProvider).volume;

  /// 按当前进度计算并应用淡入淡出音量（每次进度采样调用）。
  ///
  /// 单播放器实现：曲末渐弱、自然推进到的下一首开头渐强。
  /// 此前的「双播放器交叉淡入」只实现了一半——次播放器从未装载下一首，
  /// 曲末只是淡到静音，随后还会 `stop()` 主播放器，可能误停刚开始加载的
  /// 下一首，或在元数据时长偏短时把歌从中间掐断。
  void _applyFade(Duration position, Duration? duration) {
    final fade = _fadeDuration;
    var factor = 1.0;
    var inWindow = false;
    if (fade > Duration.zero) {
      if (_fadeInActive) {
        if (position >= fade) {
          _fadeInActive = false;
        } else {
          inWindow = true;
          factor *=
              Crossfade.levelsAt(
                position.inMilliseconds / fade.inMilliseconds,
              ).incomingVolume;
        }
      }
      // 渐弱只信播放器报告的真实时长：渠道元数据时长可能与实际音频不符
      // （试听片段、不同剪辑），按元数据算会在歌曲中途把音量降到 0。
      // 短于两倍淡入时长的曲目不做渐弱（否则整首都在变音量）。
      if (duration != null && duration > fade * 2) {
        final progress = Crossfade.progress(
          remaining: duration - position,
          duration: fade,
        );
        if (progress > 0) {
          inWindow = true;
          factor *= Crossfade.levelsAt(progress).outgoingVolume;
        }
      }
    }
    _setPlayerVolume(_baseVolume * factor);
    if (inWindow != _inFadeWindow) {
      _inFadeWindow = inWindow;
      _syncPositionTimer();
    }
  }

  void _setPlayerVolume(double volume) {
    final previous = _appliedVolume;
    if (previous != null && (volume - previous).abs() < 0.01) return;
    _appliedVolume = volume;
    unawaited(_handler.player.setVolume(volume).catchError((Object _) {}));
  }

  /// 预取下一首（在切歌成功后调用）。
  ///
  /// 只在「当前曲目剩余时间充足」时预取：太早取会因签名过期而白费，
  /// 且短曲目根本来不及听完就切了。
  void _prefetchNext(int currentIndex) {
    if (!state.hasQueue) return;
    final advance = QueueLogic.nextIndex(
      currentIndex: currentIndex,
      length: state.queue.length,
      mode: state.mode,
      shuffleOn: state.shuffleOn,
      shuffleOrder: _shuffleOrder,
    );
    if (advance == null) return; // 队尾：没有下一首
    final next = state.queue[advance.index];
    if (_prefetcher.isFreshFor(next)) return;
    _prefetcher.prefetch(next);
  }

  /// 换源提示：写入 state，由 UI `ref.listen` 后弹 SnackBar，不打断播放。
  ///
  /// 用 state 而非私有字段：私有字段无法被响应式观察到，
  /// UI 就没有办法知道发生了换源。
  void _notifySourceSwitched({required Track from, required Track to}) {
    state = state.copyWith(
      notice:
          '${_sourceName(from.sourceId)}暂不可播放，'
          '已切换到${_sourceName(to.sourceId)}',
    );
  }

  /// 只拿到试听片段时提示：否则用户听到半分钟就切歌，会以为是故障。
  void _notifyPreviewOnly(Track track) {
    state = state.copyWith(
      notice: '${_sourceName(track.sourceId)}仅提供试听片段，登录或开通会员后可播放完整版',
    );
  }

  /// 渠道展示名（「网易云音乐」而不是内部 id「netease」）。
  String _sourceName(String sourceId) =>
      ref.read(sourceRegistryProvider).resolve(sourceId)?.displayName ??
      sourceId;

  /// 清空一次性提示（UI 弹出提示后调用）。
  void clearNotice() => state = state.copyWith(notice: null);

  Future<void> _recordHistory(Track track) async {
    try {
      await ref.read(libraryRepositoryProvider).addHistory(track);
    } catch (_) {
      // 历史记录失败不影响播放
    }
  }

  /// 播放器状态回调：自然完成时自动切下一曲（含定时计数）。
  void _onPlayerStateChanged(ja.PlayerState playerState) {
    // idle（未加载任何来源）事件不驱动 UI 状态：平台初始化期间的
    // 合成事件会把用户可见状态误重置（功耗测试中暴露）。
    if (playerState.processingState == ja.ProcessingState.idle) return;
    final completed =
        playerState.processingState == ja.ProcessingState.completed;
    if (completed && !_autoAdvancing && state.hasQueue) {
      _autoAdvancing = true;
      unawaited(_advanceOnComplete());
      return;
    }
    if (completed) return;
    if (!_autoAdvancing && playerState.playing != state.playing) {
      state = state.copyWith(playing: playerState.playing);
      if (!playerState.playing) _persistResume(force: true);
    }
  }

  /// 自然播完推进：先消化「剩余 N 首」定时，再进入下一曲。
  ///
  /// [_autoAdvancing] 必须在**所有**退出路径复位（含队列尽头与
  /// 「剩余 N 首」停止）。该标志是 [_onPlayerStateChanged] 的重入闸门：
  /// 一旦泄漏为 true，播放态同步与后续自动切歌将永久失效（P0 回归）。
  Future<void> _advanceOnComplete() async {
    try {
      final remaining = state.sleepSongsRemaining;
      if (remaining != null) {
        if (remaining <= 1) {
          state = state.copyWith(sleepSongsRemaining: null);
          await _handler.pause();
          if (!_disposed) {
            state = state.copyWith(
              playing: false,
              position: state.duration ?? state.position,
            );
          }
          return;
        }
        state = state.copyWith(sleepSongsRemaining: remaining - 1);
      }
      await _next(fadeIn: true);
    } finally {
      _autoAdvancing = false;
    }
  }

  bool _disposed = false;

  /// 同步队列镜像到系统媒体中心（通知栏 / 锁屏 / 车机 / Android Auto）。
  void _syncSystemQueue() {
    _handler.publishQueue([
      for (final t in state.queue) trackToMediaItem(t),
    ], queueIndex: state.currentIndex);
  }

  /// 队列结构变更后重建洗牌序列（当前曲保持头部）。
  void _reshuffleKeepingCurrent() {
    _shuffleOrder = QueueLogic.shuffledOrder(
      state.queue.length,
      random: _random,
    );
    _moveCurrentToShuffleHead(currentIndex: state.currentIndex);
  }

  /// 进度节流刷新（可见 100ms / 不可见 1s，性能预算 §10.2 + 功耗 PW-03）。
  void _tickPosition() {
    debugPositionTicks++;
    final player = _handler.player;
    final pos = player.position;
    final dur = player.duration;
    final buffered = player.bufferedPosition;
    // 淡入淡出随位置采样推进（复用同一生命周期，不额外起定时器）
    if (state.playing && !state.loading) _applyFade(pos, dur);
    final durationUnchanged =
        (dur?.inMilliseconds ?? -1) == (state.duration?.inMilliseconds ?? -1);
    if (pos.inMilliseconds == state.position.inMilliseconds &&
        durationUnchanged &&
        buffered.inMilliseconds == state.buffered.inMilliseconds) {
      return;
    }
    state = state.copyWith(
      position: pos,
      duration: dur ?? state.duration,
      buffered: buffered,
    );
    if (state.playing) _persistResume();
  }

  // ---------- 断点续播 ----------

  /// 节流快照：force 或距上次写入 ≥15s 才落盘。
  void _persistResume({bool force = false}) {
    final resume = _resume;
    final current = state.current;
    if (resume == null || current == null) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastResumeWrite) < const Duration(seconds: 15)) {
      return;
    }
    _lastResumeWrite = now;
    unawaited(
      resume.save(
        ResumePlayback(
          queue: state.queue,
          index: state.currentIndex,
          position: state.position,
          mode: state.mode,
          shuffleOn: state.shuffleOn,
          savedAt: now,
        ),
      ),
    );
  }

  /// 恢复上次会话（队列 + 进度 + 模式）；无快照返回 false。
  Future<bool> restoreResume() async {
    final r = _resume?.load();
    if (r == null || r.queue.isEmpty) return false;
    state = state.copyWith(mode: r.mode, shuffleOn: r.shuffleOn);
    await playQueue(
      r.queue,
      startIndex: r.index,
      initialPosition:
          r.position > const Duration(seconds: 2) ? r.position : null,
    );
    return true;
  }
}

/// 实际音频是否像试听片段：曲目时长 ≥ 90 秒，而加载到的音频不超过
/// 65 秒且不到一半。阈值刻意保守——宁可漏报，不把正常的短版本误判为片段。
@visibleForTesting
bool looksLikePreviewClip({Duration? expected, Duration? actual}) {
  if (expected == null || actual == null || actual <= Duration.zero) {
    return false;
  }
  return expected >= const Duration(seconds: 90) &&
      actual <= const Duration(seconds: 65) &&
      actual * 2 < expected;
}

/// 全局播放状态 Provider。
final playerNotifierProvider = NotifierProvider<PlayerNotifier, PlayerState>(
  PlayerNotifier.new,
);

/// 断点续播快照：活跃播放中恒为 null（首页卡数据源）。
final resumePlaybackProvider = Provider<ResumePlayback?>((ref) {
  if (ref.watch(playerNotifierProvider.select((s) => s.current)) != null) {
    return null;
  }
  return ref.watch(resumeRepositoryProvider).load();
});
