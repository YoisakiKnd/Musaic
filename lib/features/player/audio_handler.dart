import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/model/track.dart';
import '../../core/utils/cover_network.dart';

/// 系统媒体集成处理器（Master Plan §7）。
///
/// 把 just_audio 播放事件 + PlayerNotifier 维护的队列镜像广播给
/// 通知栏 / 锁屏 / SMTC / Now Playing / Android Auto，并把系统侧操作
/// （媒体键、队列点跳、删除）转发回 Notifier 回调。
/// 队列的唯一事实源在 PlayerNotifier，这里只做镜像与转发。
class MusaicAudioHandler extends BaseAudioHandler with SeekHandler {
  MusaicAudioHandler({required this.player}) {
    player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object _, StackTrace __) {},
    );
    _broadcastState(player.playbackEvent);
  }

  final AudioPlayer player;

  /// 由 PlayerNotifier 注入的系统操作转发回调。
  Future<void> Function()? onNext;
  Future<void> Function()? onPrevious;
  Future<void> Function(int index)? onSkipToQueueIndex;
  Future<void> Function(String trackKey)? onRemoveQueueTrack;

  /// 当前播放曲目在队列中的下标（Notifier 每次切歌同步）。
  int _queueIndex = -1;

  // ---------- 队列镜像 ----------

  /// 全量刷新系统队列（媒体项 id 使用 track.key，供回查下标）。
  void publishQueue(List<MediaItem> items, {int queueIndex = -1}) {
    queue.add(items);
    _queueIndex =
        queueIndex >= 0 && queueIndex < items.length ? queueIndex : -1;
    playbackState.add(playbackState.value.copyWith(queueIndex: _queueIndex));
  }

  /// 切歌时更新当前元数据与队列指针。
  void updateNowPlaying(MediaItem item, {required int queueIndex}) {
    mediaItem.add(item);
    _queueIndex = queueIndex;
    playbackState.add(playbackState.value.copyWith(queueIndex: queueIndex));
  }

  // ---------- 播放控制转发 ----------

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
  Future<void> skipToQueueItem(dynamic index) async {
    // Android 侧该参数实际承载媒体项 id（可能为 int 下标或 String key），
    // 两种形态都归一到队列下标再转发 Notifier。
    final items = queue.valueOrNull;
    if (items == null || items.isEmpty) return;
    int? target;
    if (index is int) {
      target = index;
    } else {
      final key = index?.toString();
      if (key != null) {
        final found = items.indexWhere((m) => m.id == key);
        if (found >= 0) target = found;
      }
    }
    if (target != null && target >= 0 && target < items.length) {
      await onSkipToQueueIndex?.call(target);
    }
  }

  @override
  Future<void> removeQueueItem(dynamic mediaItem) async {
    final key = mediaItem is String ? mediaItem : mediaItem?.toString();
    if (key != null) await onRemoveQueueTrack?.call(key);
  }

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  // ---------- 广播 ----------

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
        queueIndex: _queueIndex,
      ),
    );
  }
}

/// Track → MediaItem（通知栏 / 锁屏 / 系统队列元数据）。
MediaItem trackToMediaItem(Track track) {
  return MediaItem(
    id: track.key,
    title: track.title,
    artist: track.artist,
    album: track.album,
    duration: track.duration,
    artUri:
        track.coverUrl == null
            ? null
            : Uri.tryParse(normalizeCoverUrl(track.coverUrl!)),
    // 通知栏 / 锁屏拉取封面时的请求头（CDN 反盗链）
    artHeaders:
        track.coverUrl == null ? null : coverHttpHeaders(track.coverUrl!),
  );
}
