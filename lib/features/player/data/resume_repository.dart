import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:meta/meta.dart';

import '../../../core/model/track.dart';
import '../domain/queue_logic.dart';

/// 上次会话的可恢复播放快照。
@immutable
class ResumePlayback {
  const ResumePlayback({
    required this.queue,
    required this.index,
    required this.position,
    required this.savedAt,
    this.mode = PlayMode.sequential,
    this.shuffleOn = false,
  });

  final List<Track> queue;
  final int index;
  final Duration position;
  final PlayMode mode;
  final bool shuffleOn;
  final DateTime savedAt;

  Track? get track => index >= 0 && index < queue.length ? queue[index] : null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'queue': queue.map((t) => t.toJson()).toList(),
    'index': index,
    'positionMs': position.inMilliseconds,
    'mode': mode.name,
    'shuffleOn': shuffleOn,
    'savedAt': savedAt.millisecondsSinceEpoch,
  };

  factory ResumePlayback.fromJson(Map<String, dynamic> json) {
    final queue =
        (json['queue'] as List<dynamic>)
            .map((t) => Track.fromJson(Map<String, dynamic>.from(t as Map)))
            .toList();
    // 越界 index 会让 [track] 恒为 null，快照被静默丢弃（旧数据 / 版本
    // 迁移后常见）。这里把 index 钳到合法区间，保证可恢复。
    final rawIndex = json['index'] as int? ?? 0;
    final index = queue.isEmpty ? -1 : rawIndex.clamp(0, queue.length - 1);
    return ResumePlayback(
      queue: queue,
      index: index,
      position: Duration(milliseconds: json['positionMs'] as int? ?? 0),
      mode: PlayMode.values.firstWhere(
        (m) => m.name == json['mode'],
        orElse: () => PlayMode.sequential,
      ),
      shuffleOn: json['shuffleOn'] as bool? ?? false,
      savedAt: DateTime.fromMillisecondsSinceEpoch(
        json['savedAt'] as int? ?? 0,
      ),
    );
  }
}

/// 断点续播持久化（Hive 独立 Box，不与设置混写）。
class ResumeRepository {
  ResumeRepository({required this.box});

  static const String boxName = 'musaic_resume';
  static const String _key = 'last';

  /// 持久化窗口上限：围绕当前曲裁剪，避免快照无界膨胀。
  static const int maxQueuePersist = 200;

  final Box<String> box;

  ResumePlayback? load() {
    final raw = box.get(_key);
    if (raw == null) return null;
    try {
      final r = ResumePlayback.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return r.track == null ? null : r;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(ResumePlayback snapshot) async {
    if (snapshot.queue.isEmpty) {
      await clear();
      return;
    }
    var queue = snapshot.queue;
    // 越界 index 会写出「无法恢复」的快照，钳到合法区间再裁剪。
    var index = snapshot.index.clamp(0, queue.length - 1);
    if (queue.length > maxQueuePersist) {
      final start = (index - 150).clamp(0, queue.length - 1);
      queue = queue.sublist(
        start,
        (start + maxQueuePersist).clamp(0, queue.length),
      );
      index = index - start;
    }
    await box.put(
      _key,
      jsonEncode(
        ResumePlayback(
          queue: queue,
          index: index,
          position: snapshot.position,
          mode: snapshot.mode,
          shuffleOn: snapshot.shuffleOn,
          savedAt: snapshot.savedAt,
        ).toJson(),
      ),
    );
  }

  Future<void> clear() => box.delete(_key);
}
