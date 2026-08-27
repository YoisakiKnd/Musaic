import 'package:meta/meta.dart';

/// 远端渠道账号歌单的统一模型（跨渠道共享）。
///
/// 渠道实现把私有歌单结构映射到本模型，UI 只依赖此抽象。
@immutable
class RemotePlaylist {
  const RemotePlaylist({
    required this.sourceId,
    required this.id,
    required this.name,
    required this.trackCount,
    this.playCount,
    this.coverUrl,
  });

  /// 来源渠道 id。
  final String sourceId;

  /// 渠道内歌单 id（字符串承载，兼容数字 / hash 两种形态）。
  final String id;

  final String name;
  final int trackCount;

  /// 播放次数（渠道不提供时为 null）。
  final int? playCount;

  final String? coverUrl;

  String get key => '$sourceId:$id';
}
