import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../../core/di/app_providers.dart';
import '../../core/error/source_exception.dart';
import '../../core/model/track.dart';
import '../../core/source/music_source.dart' show ResolvedStream;
import '../../core/network/network_config.dart';
import '../../core/theme/app_tokens.dart';
import '../../app/lifecycle/app_lifecycle.dart';
import 'audio_handler.dart';
import 'data/resume_repository.dart';
import 'domain/queue_logic.dart';

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

  @override
  PlayerState build() {
    _handler = ref.watch(audioHandlerProvider);
    _resume = ref.read(resumeRepositoryProvider);
    _handler.onNext = _onSystemSkipToNext;
    _handler.onPrevious = _onSystemSkipToPrevious;
    _handler.onSkipToQueueIndex = playAt;
    _handler.onRemoveQueueTrack = (key) {
      final index = state.queue.indexWhere((t) => t.key == key);
      if (index >= 0) return removeFromQueue(index);
      return Future.value();
    };

    _stateSub = _handler.player.playerStateStream.listen(_onPlayerStateChanged);

    // 功耗计划 PW-03：应用不可见时进度采样降为 1Hz（仅供断点快照），
    // 回前台恢复 100ms UI 预算并立即校正一次进度。
    // 直连 [AppUiVisibility]：经 Provider.listen 会把生命周期变化
    // 升级为 Notifier 重建，播放状态会被无谓重置。
    _onVisibilityChanged = _handleVisibilityChanged;
    AppUiVisibility.addListener(_onVisibilityChanged!);

    ref.onDispose(() {
      _disposed = true;
      _stateSub?.cancel();
      _positionTimer?.cancel();
      _positionTimer = null;
      _sleepTimer?.cancel();
      if (_onVisibilityChanged != null) {
        AppUiVisibility.removeListener(_onVisibilityChanged!);
        _onVisibilityChanged = null;
      }
    });

    return const PlayerState();
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
        _uiDegraded ? _backgroundPositionThrottle : AppTokens.positionThrottle;
    if (_positionTimer != null && _positionTimerPeriod == period) return;
    _positionTimer?.cancel();
    _positionTimerPeriod = period;
    _positionTimer = Timer.periodic(period, (_) => _tickPosition());
  }

  // ---------- 仅供测试观察（PW-04 空闲纪律断言） ----------

  /// 位置轮询定时器是否存活。
  @visibleForTesting
  bool get debugIsPositionTimerActive => _positionTimer != null;

  /// _tickPosition 实际执行次数（排除降级跳过）。
  @visibleForTesting
  int debugPositionTicks = 0;

  // ---------- 对外操作 ----------

  /// 用一份队列开始播放（Master Plan §3.3：UI 点歌 → playQueue）。
  Future<void> playQueue(List<Track> tracks, {int startIndex = 0}) async {
    if (tracks.isEmpty) return;
    final index = startIndex.clamp(0, tracks.length - 1);
    if (tracks.length != state.queue.length || !_sameQueue(tracks)) {
      _shuffleOrder = QueueLogic.shuffledOrder(tracks.length, random: _random);
      _moveCurrentToShuffleHead(currentIndex: index);
    }
    state = state.copyWith(
      queue: List<Track>.unmodifiable(tracks),
      currentIndex: index,
      error: null,
    );
    _syncSystemQueue();
    await _loadAndPlay(index);
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
    if (result.removedCurrent) {
      await _loadAndPlay(result.currentIndex);
    } else {
      state = state.copyWith(currentIndex: result.currentIndex);
      if (state.shuffleOn) _reshuffleKeepingCurrent();
    }
    _syncSystemQueue();
  }

  Future<void> toggle() async {
    final player = _handler.player;
    if (player.playing) {
      await player.pause();
      state = state.copyWith(playing: false);
    } else {
      if (!state.hasQueue || state.current == null) return;
      await player.play();
      state = state.copyWith(playing: true, error: null);
    }
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

  Future<void> next() async {
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
    await _loadAndPlay(advance.index);
  }

  Future<void> playAt(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    await _loadAndPlay(index);
  }

  Future<void> seekTo(Duration position) async {
    await _handler.seek(position);
    state = state.copyWith(position: position);
  }

  void setMode(PlayMode mode) => state = state.copyWith(mode: mode);

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
    try {
      await _handler.player.setSpeed(value);
      state = state.copyWith(speed: value, error: null);
    } catch (_) {
      state = state.copyWith(error: '当前平台不支持倍速播放');
    }
  }

  void clearError() => state = state.copyWith(error: null);

  Future<void> _onSystemSkipToNext() => next();

  Future<void> _onSystemSkipToPrevious() => previous();

  // ---------- 内部实现 ----------

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

  Future<void> _loadAndPlay(int index) async {
    final seq = ++_loadSeq;
    final track = state.queue[index];
    state = state.copyWith(
      currentIndex: index,
      loading: true,
      position: Duration.zero,
      buffered: Duration.zero,
      duration: track.duration,
      error: null,
    );
    _autoAdvancing = false;

    try {
      final registry = ref.read(sourceRegistryProvider);
      final source = registry.resolve(track.sourceId);
      if (source == null) {
        throw NetworkSourceException(
          '「${track.sourceId}」渠道不可用',
          sourceId: track.sourceId,
        );
      }
      final ResolvedStream resolved;
      try {
        resolved = await source
            .resolveStream(track)
            .timeout(Duration(seconds: NetworkConfig.instance.seconds * 2));
      } on TimeoutException {
        throw NetworkSourceException('解析播放地址超时', sourceId: track.sourceId);
      }
      if (seq != _loadSeq) return; // 已被更新的加载请求取代
      if (kDebugMode) {
        debugPrint(
          'MusaicPlayer stream: source=${track.sourceId} '
          '(local=${resolved.isLocalFile})',
        );
      }

      final player = _handler.player;
      if (resolved.isLocalFile) {
        await player
            .setFilePath(resolved.url)
            .timeout(const Duration(seconds: 25));
      } else {
        await player
            .setUrl(
              resolved.url,
              headers: resolved.headers ?? const <String, String>{},
            )
            .timeout(const Duration(seconds: 25));
      }
      if (seq != _loadSeq) return;
      _handler.updateNowPlaying(trackToMediaItem(track), queueIndex: index);
      // 倍速跨曲目保持（部分平台 load 后重置）
      if (state.speed != 1.0) {
        try {
          await player.setSpeed(state.speed);
        } catch (_) {}
      }
      await player.play();
      if (seq != _loadSeq) return;
      state = state.copyWith(loading: false, playing: true);

      // 记录最近播放与断点快照起点（本地优先存储，失败静默）
      unawaited(_recordHistory(track));
      _persistResume(force: true);
    } on SourceException catch (e) {
      if (seq != _loadSeq) return;
      debugPrint('MusaicPlayer SourceException: ${e.message}');
      state = state.copyWith(loading: false, playing: false, error: e.message);
    } catch (e, st) {
      if (seq != _loadSeq) return;
      debugPrint('MusaicPlayer 播放异常: $e');
      debugPrint(
        'MusaicPlayer 堆栈首行: ${st.toString().split('\n').take(4).join(' | ')}',
      );
      state = state.copyWith(
        loading: false,
        playing: false,
        error: '播放失败，请稍后重试',
      );
    }
  }

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
  Future<void> _advanceOnComplete() async {
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
    await next();
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
    await playQueue(r.queue, startIndex: r.index);
    if (r.position > const Duration(seconds: 2)) {
      await seekTo(r.position);
    }
    return true;
  }
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
