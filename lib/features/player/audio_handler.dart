import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

/// 系统媒体集成处理器（Master Plan §7）。
///
/// 负责把 just_audio 的播放事件广播给通知栏 / 锁屏 / SMTC / Now Playing，
/// 并把耳机按键、系统上一首/下一首转发回 [onNext]/[onPrevious] 回调
/// （回调由 PlayerNotifier 注入，队列逻辑集中在 Notifier 一处）。
class MusaicAudioHandler extends BaseAudioHandler with SeekHandler {
  MusaicAudioHandler({required this.player}) {
    player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object _, StackTrace __) {},
    );
    _broadcastState(player.playbackEvent);
  }

  final AudioPlayer player;

  /// 由 PlayerNotifier 注入的切歌回调。
  Future<void> Function()? onNext;
  Future<void> Function()? onPrevious;

  /// 切歌时由 Notifier 更新元数据。
  void updateNowPlaying(MediaItem item) {
    mediaItem.add(item);
  }

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToNext() async => onNext?.call();

  @override
  Future<void> skipToPrevious() async => onPrevious?.call();

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  void _broadcastState(PlaybackEvent event) {
    final playing = player.playing;
    final processing = switch (player.processingState) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.buffering,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToPrevious,
          MediaControl.skipToNext,
        ],
        systemActions: const <MediaAction>{
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        processingState: processing,
        playing: playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
        queueIndex: event.currentIndex,
      ),
    );
  }
}

/// 构建 MediaItem（通知栏 / 锁屏元数据）。
MediaItem trackToMediaItem({
  required String id,
  required String title,
  required String artist,
  String? album,
  Duration? duration,
  String? artUri,
}) {
  return MediaItem(
    id: id,
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    artUri: artUri == null ? null : Uri.tryParse(artUri),
  );
}
