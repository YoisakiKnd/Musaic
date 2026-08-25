import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../../core/di/app_providers.dart';
import '../../core/error/source_exception.dart';
import '../../core/model/track.dart';
import '../../core/theme/app_tokens.dart';
import 'audio_handler.dart';
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
    this.sleepTimerEndsAt,
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

  /// 定时关闭时间点；null 表示未启用。
  final DateTime? sleepTimerEndsAt;

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
    Object? sleepTimerEndsAt = _unset,
    Object? error = _unset,
  }) {
    return PlayerState(
      queue:
          identical(queue, _unset) ? this.queue : queue! as List<Track>,
      currentIndex: currentIndex ?? this.currentIndex,
      playing: playing ?? this.playing,
      loading: loading ?? this.loading,
      position: position ?? this.position,
      buffered: buffered ?? this.buffered,
      duration:
          identical(duration, _unset) ? this.duration : duration as Duration?,
      mode: mode ?? this.mode,
      shuffleOn: shuffleOn ?? this.shuffleOn,
      sleepTimerEndsAt: identical(sleepTimerEndsAt, _unset)
          ? this.sleepTimerEndsAt
          : sleepTimerEndsAt as DateTime?,
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
  Timer? _sleepTimer;
  bool _autoAdvancing = false;
  final Random _random = Random();

  /// 随机模式洗牌序列（shuffleOn=false 时忽略）。
  List<int>? _shuffleOrder;

  @override
  PlayerState build() {
    _handler = ref.watch(audioHandlerProvider);
    _handler.onNext = _onSystemSkipToNext;
    _handler.onPrevious = _onSystemSkipToPrevious;

    _stateSub = _handler.player.playerStateStream.listen(_onPlayerStateChanged);
    _positionTimer = Timer.periodic(
      AppTokens.positionThrottle,
      (_) => _tickPosition(),
    );

    ref.onDispose(() {
      _stateSub?.cancel();
      _positionTimer?.cancel();
      _sleepTimer?.cancel();
    });

    return const PlayerState();
  }

  // ---------- 对外操作 ----------

  /// 用一份队列开始播放（Master Plan §3.3：UI 点歌 → playQueue）。
  Future<void> playQueue(List<Track> tracks, {int startIndex = 0}) async {
    if (tracks.isEmpty) return;
    final index = startIndex.clamp(0, tracks.length - 1);
    if (tracks.length != state.queue.length || !_sameQueue(tracks)) {
      _shuffleOrder =
          QueueLogic.shuffledOrder(tracks.length, random: _random);
      _moveCurrentToShuffleHead(currentIndex: index);
    }
    state = state.copyWith(
      queue: List<Track>.unmodifiable(tracks),
      currentIndex: index,
      error: null,
    );
    await _loadAndPlay(index);
  }

  /// 追加到队尾。
  void addToQueue(Track track) {
    final queue = [...state.queue, track];
    if (state.shuffleOn) {
      _shuffleOrder =
          QueueLogic.shuffledOrder(queue.length, random: _random);
      _moveCurrentToShuffleHead(currentIndex: state.currentIndex);
    }
    state = state.copyWith(queue: queue);
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
  Future<void> previous({bool manual = true}) async {
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

  Future<void> next({bool manual = true}) async {
    if (!state.hasQueue) return;
    final advance = QueueLogic.nextIndex(
      currentIndex: state.currentIndex,
      length: state.queue.length,
      mode: state.mode,
      shuffleOn: state.shuffleOn,
      shuffleOrder: _shuffleOrder,
    );
    if (advance == null) {
      state = state.copyWith(
        playing: false,
        position: state.duration ?? state.position,
      );
      return;
    }
    if (advance.wrapped && state.shuffleOn) {
      _shuffleOrder =
          QueueLogic.shuffledOrder(state.queue.length, random: _random);
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
      _shuffleOrder =
          QueueLogic.shuffledOrder(state.queue.length, random: _random);
      _moveCurrentToShuffleHead(currentIndex: state.currentIndex);
    }
    state = state.copyWith(shuffleOn: shuffleOn);
  }

  /// 定时关闭：传 null 取消（对齐 Mei 的定时播放）。
  void setSleepTimer(Duration? remaining) {
    _sleepTimer?.cancel();
    if (remaining == null) {
      state = state.copyWith(sleepTimerEndsAt: null);
      return;
    }
    state = state.copyWith(
      sleepTimerEndsAt: DateTime.now().add(remaining),
    );
    _sleepTimer = Timer(remaining, () async {
      try {
        await _handler.pause();
      } finally {
        state = state.copyWith(playing: false, sleepTimerEndsAt: null);
      }
    });
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
      final resolved = await source.resolveStream(track);

      final player = _handler.player;
      if (resolved.isLocalFile) {
        await player.setFilePath(resolved.url);
      } else {
        await player.setUrl(
          resolved.url,
          headers: resolved.headers ?? const <String, String>{},
        );
      }
      _handler.updateNowPlaying(
        trackToMediaItem(
          id: track.key,
          title: track.title,
          artist: track.artist,
          album: track.album,
          duration: track.duration,
          artUri: track.coverUrl,
        ),
      );
      await player.play();
      state = state.copyWith(loading: false, playing: true);

      // 记录最近播放（本地优先存储，失败静默）
      unawaited(_recordHistory(track));
    } on SourceException catch (e) {
      state = state.copyWith(loading: false, playing: false, error: e.message);
    } catch (_) {
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

  /// 播放器状态回调：自然完成时自动切下一曲。
  void _onPlayerStateChanged(ja.PlayerState playerState) {
    final completed =
        playerState.processingState == ja.ProcessingState.completed;
    if (completed && !_autoAdvancing && state.hasQueue) {
      _autoAdvancing = true;
      unawaited(next());
      return;
    }
    if (completed) return;
    if (!_autoAdvancing && playerState.playing != state.playing) {
      state = state.copyWith(playing: playerState.playing);
    }
  }

  /// 进度节流刷新（100ms，性能预算 Master Plan §10.2）。
  void _tickPosition() {
    final player = _handler.player;
    final pos = player.position;
    final dur = player.duration;
    final buffered = player.bufferedPosition;
    final durationUnchanged = (dur?.inMilliseconds ?? -1) ==
        (state.duration?.inMilliseconds ?? -1);
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
  }
}

/// 全局播放状态 Provider。
final playerNotifierProvider =
    NotifierProvider<PlayerNotifier, PlayerState>(PlayerNotifier.new);
