import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/model/track.dart';
import '../../../core/lyrics/lyric_bundle.dart';
import '../data/lyrics_cache_repository.dart';

/// 歌词解析 Provider（Master Plan §3.3 歌词流）。
///
/// 先查磁盘缓存（[LyricsCacheRepository]），未命中再请求渠道；
/// 渠道内部已完成「官方逐字 > TTML > LRC」三级降级，无歌词返回 null。
/// 拿到的歌词异步落盘，写缓存失败不影响本次展示。
final lyricsProvider = FutureProvider.autoDispose.family<LyricBundle?, Track>((
  ref,
  track,
) async {
  final cache = ref.watch(lyricsCacheRepositoryProvider);
  final cacheable = cache != null && LyricsCacheRepository.isCacheable(track);
  if (cacheable) {
    final hit = await cache.read(track.key);
    if (hit != null) return hit;
  }

  final registry = ref.watch(sourceRegistryProvider);
  final source = registry.resolve(track.sourceId);
  if (source == null) return null;
  final bundle = await source.fetchLyrics(track);
  if (cacheable && bundle != null) {
    unawaited(
      cache.write(track.key, bundle).catchError((Object e) {
        AppLog.debug('歌词缓存写入失败：$e', tag: 'MusaicLyricsCache');
      }),
    );
  }
  return bundle;
});
