import 'dart:convert';

import 'package:hive/hive.dart';

import '../../../core/lyrics/lyric_bundle.dart';
import '../../../core/lyrics/lyric_codec.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/model/track.dart';

/// 歌词磁盘缓存（架构演进设计 §3.1 / S6 第一步）。
///
/// 此前 `lyricsProvider` 是 `autoDispose.family`：每次进播放页都重新请求，
/// 离线/弱网下已经听过的歌也没有歌词。本仓库把成功拿到的歌词落盘。
///
/// 设计取舍：
/// - **键为 [Track.key] 而非 WorkId**：不同渠道的同一首歌是不同录音/剪辑，
///   时间轴并不通用，按作品共享歌词会出现整体错位。
/// - **只缓存「有歌词」**：各渠道 `fetchLyrics` 把网络失败也吞成 null，
///   分不清「真的没有歌词」与「这次没拿到」。缓存 null 会把一次断网
///   固化成长期无歌词，因此宁可每次重试。
/// - **本地文件不缓存**：本地歌词来自同名 `.lrc`，读取本身就是本地 IO，
///   而且用户改了 `.lrc` 应立即生效。
/// - **有效期 [maxAge]**：渠道偶尔会补充翻译或逐字时间轴，过期后重拉覆盖。
/// - **容量 [capacity] 条，按写入时间淘汰最旧**：读路径零写入
///   （按访问时间的 LRU 需要每次命中都改写整条歌词，得不偿失）。
///
/// 值格式为 `"<写入毫秒>\n<JSON>"`：淘汰时只需解析换行前的时间戳，
/// 不必为几百条歌词逐条 `jsonDecode`。
class LyricsCacheRepository {
  LyricsCacheRepository({
    required Box<String> box,
    this.capacity = defaultCapacity,
    this.maxAge = defaultMaxAge,
    DateTime Function()? clock,
  }) : _box = box,
       _clock = clock ?? DateTime.now;

  static const String boxName = 'musaic_lyrics_cache';
  static const int defaultCapacity = 300;
  static const Duration defaultMaxAge = Duration(days: 30);

  final Box<String> _box;
  final int capacity;
  final Duration maxAge;
  final DateTime Function() _clock;

  /// 该曲目的歌词是否走缓存。
  static bool isCacheable(Track track) => track.sourceId != 'local';

  /// 已缓存的歌词条数（设置页展示）。
  int get count => _box.length;

  /// 读取缓存；未命中、已过期或数据损坏均返回 null。
  LyricBundle? read(String trackKey) {
    final raw = _box.get(trackKey);
    if (raw == null) return null;
    final split = raw.indexOf('\n');
    final writtenAt = split > 0 ? int.tryParse(raw.substring(0, split)) : null;
    if (writtenAt == null) return null;
    final age = _clock().millisecondsSinceEpoch - writtenAt;
    if (age > maxAge.inMilliseconds) return null;
    try {
      return LyricCodec.decode(jsonDecode(raw.substring(split + 1)));
    } catch (_) {
      return null;
    }
  }

  /// 写入缓存；空歌词不写。超出容量时淘汰最旧的条目。
  Future<void> write(String trackKey, LyricBundle bundle) async {
    if (bundle.isEmpty) return;
    final now = _clock().millisecondsSinceEpoch;
    await _box.put(trackKey, '$now\n${jsonEncode(LyricCodec.encode(bundle))}');
    if (_box.length > capacity) await _evictOldest();
  }

  Future<void> clear() => _box.clear();

  /// 一次淘汰到容量的 90%，避免每次写入都触发一轮全表扫描。
  Future<void> _evictOldest() async {
    final target = (capacity * 0.9).floor();
    final dated = <(int, String)>[];
    for (final key in _box.keys) {
      final raw = _box.get(key) ?? '';
      final split = raw.indexOf('\n');
      final at = split > 0 ? int.tryParse(raw.substring(0, split)) : null;
      dated.add((at ?? 0, '$key'));
    }
    dated.sort((a, b) => a.$1.compareTo(b.$1));
    final overflow = dated.length - target;
    if (overflow <= 0) return;
    await _box.deleteAll([for (var i = 0; i < overflow; i++) dated[i].$2]);
    AppLog.debug('歌词缓存淘汰 $overflow 条', tag: 'MusaicLyricsCache');
  }
}
