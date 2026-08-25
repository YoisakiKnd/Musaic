import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/model/track.dart';
import '../../core/source/source_registry.dart';
import 'package:just_audio/just_audio.dart';

enum PlayMode { sequence, repeatOne, shuffle }

class PlayerState {
  const PlayerState({
    required this.queue,
    required this.currentIndex,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.playMode,
    required this.currentTrack,
  });

  factory PlayerState.initial() => const PlayerState(
        queue: [],
        currentIndex: 0,
        position: Duration.zero,
        duration: Duration.zero,
        isPlaying: false,
        playMode: PlayMode.sequence,
        currentTrack: null,
      );

  final List<Track> queue;
  final int currentIndex;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final PlayMode playMode;
  final Track? currentTrack;

  PlayerState copyWith({
    List<Track>? queue,
    int? currentIndex,
    Duration? position,
    Duration? duration,
    bool? isPlaying,
    PlayMode? playMode,
    Track? currentTrack,
  }) {
    return PlayerState(
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      isPlaying: isPlaying ?? this.isPlaying,
      playMode: playMode ?? this.playMode,
      currentTrack: currentTrack ?? this.currentTrack,
    );
  }
}

class PlayerNotifier extends Notifier<PlayerState> {
  PlayerNotifier(this._registry);

  final SourceRegistry _registry;
  late final AudioPlayer _player = AudioPlayer();

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<void>? _completedSubscription;

  PlayerState build() {
    _bindPlayer();
    return PlayerState.initial();
  }

  void _bindPlayer() {
    _positionSubscription = _player.positionStream.listen((position) {
      state = state.copyWith(position: position);
    });
    _durationSubscription = _player.durationStream.listen((duration) {
      state = state.copyWith(duration: duration ?? Duration.zero);
    });
    _player.playerStateStream.listen((playerState) {
      final processingState = playerState.processingState;
      if (processingState == ProcessingState.completed) {
        if (state.playMode == PlayMode.repeatOne) {
          _player.seek(Duration.zero);
          _player.play();
        } else {
          next();
        }
      }
    });
  }

  Future<void> playQueue(List<Track> queue, int startIndex) async {
    if (queue.isEmpty) return;
    state = state.copyWith(queue: queue, currentIndex: startIndex);
    await _playCurrent();
  }

  Future<void> _playCurrent() async {
    final track = state.currentTrack;
    if (track == null) return;
    final source = _registry.resolve(track.sourceId);
    if (source == null) return;
    try {
      final url = await source.getStreamUrl(track);
      await _player.setUrl(url);
      state = state.copyWith(isPlaying: true);
      await _player.play();
    } catch (e) {
      // TODO: handle playback error
    }
  }

  Future<void> play() async {
    if (_player.playing) return;
    state = state.copyWith(isPlaying: true);
    await _player.play();
  }

  Future<void> pause() async {
    if (!_player.playing) return;
    state = state.copyWith(isPlaying: false);
    await _player.pause();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> next() async {
    if (state.queue.isEmpty) return;
    final mode = state.playMode;
    int nextIndex;
    if (mode == PlayMode.shuffle) {
      nextIndex = (state.currentIndex + 1 + (_player.position.inMilliseconds % state.queue.length)).clamp(0, state.queue.length - 1);
    } else {
      nextIndex = (state.currentIndex + 1) % state.queue.length;
    }
    state = state.copyWith(currentIndex: nextIndex);
    await _playCurrent();
  }

  Future<void> previous() async {
    if (state.queue.isEmpty) return;
    final position = _player.position;
    final current = state.currentIndex;
    int prevIndex;
    if (position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    prevIndex = (current - 1 + state.queue.length) % state.queue.length;
    state = state.copyWith(currentIndex: prevIndex);
    await _playCurrent();
  }

  void setPlayMode(PlayMode mode) {
    state = state.copyWith(playMode: mode);
  }

  void dispose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _completedSubscription?.cancel();
    _player.dispose();
  }
}

final playerNotifierProvider =
    NotifierProvider<PlayerNotifier, PlayerState>(() {
  throw UnimplementedError('playerNotifierProvider must be overridden');
});
