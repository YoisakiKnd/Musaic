import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/model/track.dart';
import '../domain/lyric_bundle.dart';

/// 歌词解析 Provider（Master Plan §3.3 歌词流）。
///
/// 按曲目自动缓存与释放（autoDispose）；渠道内部已完成
/// 「官方逐字 > TTML > LRC」三级降级，无歌词返回 null。
final lyricsProvider = FutureProvider.autoDispose
    .family<LyricBundle?, Track>((ref, track) async {
  final registry = ref.watch(sourceRegistryProvider);
  final source = registry.resolve(track.sourceId);
  if (source == null) return null;
  return source.fetchLyrics(track);
});
