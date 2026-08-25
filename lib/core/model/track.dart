import 'package:meta/meta.dart';

/// 统一曲目模型
///
/// 所有渠道返回的曲目必须转换为该模型，携带 [sourceId] 以标识来源。
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

  factory Track.fromJson(Map<String, dynamic> json) => Track(
        id: json['id'] as String,
        sourceId: json['sourceId'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String,
        album: json['album'] as String?,
        duration: json['duration'] != null
            ? Duration(milliseconds: json['duration'] as int)
            : null,
        coverUrl: json['coverUrl'] as String?,
        sourceData: json['sourceData'] != null
            ? Map<String, dynamic>.from(json['sourceData'] as Map)
            : null,
      );

  factory Track.fromMap(Map<String, dynamic> map) => Track(
        id: map['id'] as String,
        sourceId: map['sourceId'] as String,
        title: map['title'] as String,
        artist: map['artist'] as String,
        album: map['album'] as String?,
        duration: map['duration'] != null
            ? Duration(milliseconds: map['duration'] as int)
            : null,
        coverUrl: map['coverUrl'] as String?,
        sourceData: null,
      );

  final String id;
  final String sourceId;
  final String title;
  final String artist;
  final String? album;
  final Duration? duration;
  final String? coverUrl;
  final Map<String, dynamic>? sourceData;

  String get displayTitle => title;
  String get displaySubtitle => artist;

  Track copyWith({
    String? id,
    String? sourceId,
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? coverUrl,
    Map<String, dynamic>? sourceData,
  }) {
    return Track(
      id: id ?? this.id,
      sourceId: sourceId ?? this.sourceId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      coverUrl: coverUrl ?? this.coverUrl,
      sourceData: sourceData ?? this.sourceData,
    );
  }

  Map<String, dynamic> toJson() => {
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
  String toString() => 'Track(id: $id, sourceId: $sourceId, title: $title, artist: $artist)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Track &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          sourceId == other.sourceId;

  @override
  int get hashCode => Object.hash(id, sourceId);
}
