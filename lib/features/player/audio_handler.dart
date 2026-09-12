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
  MusaicAudioHandler({required this.player, AudioPlayer? secondary})
    : _secondary = secondary {
    player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object _, StackTrace __) {},
    );
    _broadcastState(player.playbackEvent);
  }

  /// 主播放器：**系统媒体状态的事实源**。
  ///
  /// 双播放器仅用于交叉淡入（N4）。无论哪一路在出声，通知栏/锁屏/媒体键
  /// 都只反映 [player] 的状态——这是刻意设计：让第二路去驱动 playbackState
  /// 会造成「通知栏显示暂停、实际还在出声」这类脱同步
  /// （本项目已多次修过同类问题：`_autoAdvancing` 泄漏、系统队列删歌）。
  final AudioPlayer player;

  /// 次播放器：仅在交叉淡入期间使用，不参与状态广播。
  ///
  /// 为 null 表示未启用交叉淡入（默认）。
  final AudioPlayer? _secondary;

  /// 交叉淡入用的次播放器（未启用时为 null）。
  AudioPlayer? get secondaryPlayer => _secondary;

  /// 当前**正在出声**的播放器。
  ///
  /// 交叉淡入切换期间，实际出声的可能不是 [player]。播放控制
  /// （play/pause/seek）需作用于它，否则会出现「暂停了但还在响」。
  AudioPlayer? _activeOverride;

  /// 标记当前由哪一路出声；传 null 恢复主播放器。
  void setActivePlayer(AudioPlayer? active) => _activeOverride = active;

  /// 实际出声的播放器（默认主播放器）。
  AudioPlayer get activePlayer => _activeOverride ?? player;

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
  Future<void> play() => activePlayer.play();

  @override
  Future<void> pause() async {
    // 交叉淡入期间两路可能同时在放，必须都停——只停一路会「按了暂停还在响」
    await activePlayer.pause();
    if (!identical(activePlayer, player)) await player.pause();
    if (_secondary != null && !identical(activePlayer, _secondary)) {
      await _secondary.pause();
    }
  }

  @override
  Future<void> seek(Duration position) => activePlayer.seek(position);

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
    // Android 侧传入的是 MediaItem 实例，其 toString() 是整包 Map 序列化，
    // 与 track.key 永不相等 → 通知栏/车机删歌静默失效。
    // 必须按类型取出 id（P1 回归守护）。
    final String? key = switch (mediaItem) {
      null => null,
      MediaItem() => mediaItem.id,
      String() => mediaItem,
      _ => mediaItem.toString(),
    };
    if (key != null && key.isNotEmpty) {
      await onRemoveQueueTrack?.call(key);
    }
  }

  @override
  Future<void> stop() async {
    await player.stop();
    await _secondary?.stop();
    _activeOverride = null;
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
