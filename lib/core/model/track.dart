import 'package:meta/meta.dart';

/// 统一曲目模型（Master Plan §4 / §6.1）。
///
/// 所有渠道返回的曲目必须转换为该模型；[sourceId] 标识来源渠道，
/// [id] 为该渠道内的唯一标识。[sourceData] 携带渠道私有数据（如网易云歌曲 id），
/// 不参与相等性判断，序列化时保留以便恢复队列。
@immutable
class Track {
  const Track({
    required this.id,
    required this.sourceId,
    required this.title,
    required this.artist,
    this.album,
    this.duration,
    this.coverUrl,
    this.sourceData,
  });

  factory Track.fromJson(Map<String, dynamic> json) {
    final rawDuration = json['duration'];
    final rawCover = json['coverUrl'];
    final rawSource = json['sourceData'];
    return Track(
      id: json['id']! as String,
      sourceId: json['sourceId']! as String,
      title: json['title']! as String,
      artist: json['artist']! as String,
      album: json['album'] as String?,
      duration: rawDuration == null
          ? null
          : Duration(milliseconds: rawDuration as int),
      coverUrl: rawCover as String?,
      sourceData: rawSource == null
          ? null
          : Map<String, dynamic>.from(rawSource as Map<dynamic, dynamic>),
    );
  }

  final String id;
  final String sourceId;
  final String title;
  final String artist;
  final String? album;
  final Duration? duration;
  final String? coverUrl;

  /// 渠道私有附加数据（例如 `{'neteaseId': 123}` 或本地文件路径）。
  final Map<String, dynamic>? sourceData;

  /// 稳定唯一键，用于收藏 / 历史 / 歌词缓存等按曲索引的场景。
  String get key => '$sourceId:$id';

  Track copyWith({
    String? id,
    String? sourceId,
    String? title,
    String? artist,
    Object? album = _unset,
    Object? duration = _unset,
    Object? coverUrl = _unset,
    Object? sourceData = _unset,
  }) {
    return Track(
      id: id ?? this.id,
      sourceId: sourceId ?? this.sourceId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: identical(album, _unset) ? this.album : album as String?,
      duration:
          identical(duration, _unset) ? this.duration : duration as Duration?,
      coverUrl:
          identical(coverUrl, _unset) ? this.coverUrl : coverUrl as String?,
      sourceData: identical(sourceData, _unset)
          ? this.sourceData
          : sourceData as Map<String, dynamic>?,
    );
  }

  static const Object _unset = Object();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'sourceId': sourceId,
        'title': title,
        'artist': artist,
        if (album != null) 'album': album,
        if (duration != null) 'duration': duration!.inMilliseconds,
        if (coverUrl != null) 'coverUrl': coverUrl,
        if (sourceData != null) 'sourceData': sourceData,
      };

  @override
  String toString() =>
      'Track($key, title: $title, artist: $artist)'; // 日志不含凭据类信息

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Track && other.key == key;

  @override
  int get hashCode => key.hashCode;
}
