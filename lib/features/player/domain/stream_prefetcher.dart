/// 播放地址预取（改进计划 P2「点歌到出声延迟」）。
///
/// ## 为什么需要
///
/// 当前每次切歌都是**串行**两段网络等待：
/// 1. `resolveStream`：渠道解析真实播放地址（可能含重定向、签名）；
/// 2. 播放器 `setUrl`：DNS + TLS + 首包缓冲。
///
/// 用户点「下一首」时才开始这两步，所以能明显感到延迟。
/// 预取把第 1 步提前到**当前曲还剩足够时间**时完成，点歌时只剩第 2 步。
///
/// ## 为什么不做成 gapless
///
/// gapless（曲间无缝）需要 `ConcatenatingAudioSource` 预排队**多个**音源，
/// 与 Musaic「每次播放实时 resolve、不缓存过期 URL」的既有设计冲突较大，
/// 且四渠道的 URL 多为**短时效签名地址**——提前太久排队会在播放时已失效。
/// 因此先做预取（收益明确、风险低），gapless 留待单独评估。
///
/// ## 安全边界
///
/// 预取结果**只作为一次性加速**，绝不做长期缓存：
/// - 命中后立即失效，避免用到过期签名；
/// - 队列/曲目变化时整体作废；
/// - 失败静默（预取只是优化，不该产生任何用户可见错误）。
library;

import 'dart:async';

import '../../../core/model/track.dart';
import '../../../core/source/music_source.dart';

/// 一次预取的结果。
class PrefetchEntry {
  PrefetchEntry({required this.trackKey, required this.stream});

  final String trackKey;
  final ResolvedStream stream;

  /// 创建时间：用于判断是否可能已过期。
  final DateTime createdAt = DateTime.now();
}

/// 播放地址预取器。
///
/// 只保存**一条**（下一首）结果：预取的价值在于「点歌瞬间已就绪」，
/// 而缓存多首既增加失效风险，也几乎不提升命中率（用户通常顺序播放）。
class StreamPrefetcher {
  StreamPrefetcher({required this.resolve, this.maxAge = kDefaultMaxAge});

  /// 实际的解析函数（由调用方注入，便于单测）。
  final Future<ResolvedStream?> Function(Track track) resolve;

  /// 预取结果的最长可用时间。
  ///
  /// 各渠道播放地址多为**短时效签名 URL**，超过该时间即视为不可信，
  /// 宁可重新解析也不要用一个可能 403 的地址。
  final Duration maxAge;

  /// 默认有效期：3 分钟。足够覆盖「听完当前曲的前奏再点下一首」，
  /// 又不至于长到让签名过期。
  static const Duration kDefaultMaxAge = Duration(minutes: 3);

  PrefetchEntry? _entry;
  String? _inFlightKey;
  Future<void>? _inFlight;

  /// 当前是否有预取结果可用（仅供测试与诊断）。
  bool get hasEntry => _entry != null;

  /// 正在预取的曲目 key（null 表示空闲）。
  String? get inFlightKey => _inFlightKey;

  /// 预取 [track] 的播放地址。
  ///
  /// 重复调用同一首会被忽略（避免同一目标并发解析）。
  /// 任何失败都静默——预取是优化，不是功能。
  void prefetch(Track track) {
    final existing = _entry;
    // 已就绪且未过期：无需重复解析。
    // 过期则继续往下走（重新取），否则长曲目永远等不到可用结果。
    if (existing != null &&
        existing.trackKey == track.key &&
        !_isExpired(existing)) {
      return;
    }
    if (_inFlightKey == track.key) return; // 正在取
    // 已有其它目标的预取在跑：不打断（它可能马上完成），但换目标
    _inFlightKey = track.key;
    final future = _run(track);
    _inFlight = future;
  }

  Future<void> _run(Track track) async {
    try {
      final stream = await resolve(track);
      if (stream == null) return;
      // 只有仍是当前目标才落盘（期间可能已切到别的曲目）
      if (_inFlightKey != track.key) return;
      _entry = PrefetchEntry(trackKey: track.key, stream: stream);
    } catch (_) {
      // 预取失败不影响任何用户可见行为
    } finally {
      if (_inFlightKey == track.key) _inFlightKey = null;
    }
  }

  bool _isExpired(PrefetchEntry entry) =>
      DateTime.now().difference(entry.createdAt) > maxAge;

  /// 指定曲目是否已有**未过期**的预取结果（供调用方避免无谓重复调用）。
  bool isFreshFor(Track track) {
    final entry = _entry;
    return entry != null && entry.trackKey == track.key && !_isExpired(entry);
  }

  /// 取出预取结果（若命中且未过期），并**立即失效**。
  ///
  /// 一次性语义很重要：签名 URL 用掉一次后不应再被复用，
  /// 否则重播同一首可能拿到已失效地址。
  ResolvedStream? take(Track track) {
    final entry = _entry;
    if (entry == null) return null;
    if (entry.trackKey != track.key) return null;
    _entry = null;
    if (_isExpired(entry)) {
      return null; // 已过期：宁可重新解析
    }
    return entry.stream;
  }

  /// 作废全部预取（队列变化、清空队列、切换渠道等场景）。
  void invalidate() {
    _entry = null;
    _inFlightKey = null;
  }

  /// 等待正在进行的预取结束（仅供测试与优雅关闭）。
  Future<void> get settled => _inFlight ?? Future<void>.value();
}
