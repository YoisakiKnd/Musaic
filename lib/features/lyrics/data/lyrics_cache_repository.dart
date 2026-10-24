import 'dart:convert';

import 'package:hive/hive.dart';

import '../../../core/lyrics/lyric_bundle.dart';
import '../../../core/lyrics/lyric_codec.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/model/track.dart';
import '../../../core/storage/schema_migrator.dart';

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
///
/// 存储用 [LazyBox]：只有键常驻内存，值按需从磁盘读。普通 Box 会在启动时
/// 把全部歌词读进内存（逐字歌词单条就有几十 KB），而播放时一次只用一条。
class LyricsCacheRepository {
  LyricsCacheRepository({
    required LazyBox<String> box,
    this.capacity = defaultCapacity,
    this.maxAge = defaultMaxAge,
    DateTime Function()? clock,
  }) : _box = box,
       _clock = clock ?? DateTime.now;

  static const String boxName = 'musaic_lyrics_cache';
  static const int defaultCapacity = 300;
  static const Duration defaultMaxAge = Duration(days: 30);

  final LazyBox<String> _box;
  final int capacity;
  final Duration maxAge;
  final DateTime Function() _clock;

  /// 尚未落盘的写入。懒加载 Box 的值只能从磁盘读，写入完成前读不到；
  /// 不兜这一层，刚拉到歌词就切回同一首会再请求一次渠道。
  final Map<String, String> _pending = <String, String>{};

  /// 该曲目的歌词是否走缓存。
  static bool isCacheable(Track track) => track.sourceId != 'local';

  /// 已缓存的歌词条数（设置页展示）。
  int get count => _entryKeys.length;

  /// 歌词条目的键（排除旧版本 schema 迁移写入的元数据键）。
  Iterable<String> get _entryKeys => _box.keys
      .map((k) => '$k')
      .where((k) => !k.startsWith(SchemaMigrator.reservedPrefix));

  /// 读取缓存；未命中、已过期或数据损坏均返回 null。
  Future<LyricBundle?> read(String trackKey) async {
    final raw = _pending[trackKey] ?? await _box.get(trackKey);
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
    final value = '$now\n${jsonEncode(LyricCodec.encode(bundle))}';
    _pending[trackKey] = value;
    try {
      await _box.put(trackKey, value);
    } finally {
      if (identical(_pending[trackKey], value)) _pending.remove(trackKey);
    }
    if (count > capacity) await _evictOldest();
  }

  Future<void> clear() {
    _pending.clear();
    return _box.clear();
  }

  /// 一次淘汰到容量的 90%，避免每次写入都触发一轮全表扫描。
  Future<void> _evictOldest() async {
    final target = (capacity * 0.9).floor();
    final dated = <(int, String)>[];
    // 懒加载 Box 需逐条读盘；淘汰一次清掉 10%，摊到每次写入很便宜
    for (final key in _entryKeys.toList()) {
      final raw = await _box.get(key) ?? '';
      final split = raw.indexOf('\n');
      final at = split > 0 ? int.tryParse(raw.substring(0, split)) : null;
      dated.add((at ?? 0, key));
    }
    dated.sort((a, b) => a.$1.compareTo(b.$1));
    final overflow = dated.length - target;
    if (overflow <= 0) return;
    await _box.deleteAll([for (var i = 0; i < overflow; i++) dated[i].$2]);
    AppLog.debug('歌词缓存淘汰 $overflow 条', tag: 'MusaicLyricsCache');
  }
}
