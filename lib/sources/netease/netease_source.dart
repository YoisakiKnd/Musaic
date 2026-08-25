import 'package:dio/dio.dart';

import '../../core/model/track.dart';
import '../../core/source/music_source.dart';

/// 网易云音乐渠道。
///
/// P2 实现匿名搜索与播放，P3 接入 Cookie 登录。
class NeteaseSource extends MusicSource {
  NeteaseSource({Dio? dio}) : _dio = dio ?? Dio(BaseOptions(baseUrl: _baseUrl));

  static const _baseUrl = 'https://music.163.com';
  final Dio _dio;

  @override
  String get sourceId => 'netease';

  @override
  String get sourceName => '网易云音乐';

  @override
  Future<List<Track>> search(String query) async {
    try {
      final response = await _dio.post(
        '/api/search/get',
        data: {
          's': query,
          'type': 1, // 1 = 单曲
          'limit': 30,
          'offset': 0,
        },
        options: Options(
          headers: {
            'Referer': 'https://music.163.com/',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        ),
      );

      final result = response.data;
      if (result is Map<String, dynamic> && result['code'] == 200) {
        final songs = result['result']?['songs'] as List<dynamic>? ?? [];
        return songs.map((song) => _toTrack(song)).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  @override
  Future<Track> getTrackDetail(Track track) async {
    try {
      final response = await _dio.post(
        '/api/song/detail',
        data: {
          'ids': '[${track.id}]',
        },
        options: Options(
          headers: {
            'Referer': 'https://music.163.com/',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        ),
      );

      final result = response.data;
      if (result is Map<String, dynamic> && result['code'] == 200) {
        final songs = result['songs'] as List<dynamic>? ?? [];
        if (songs.isNotEmpty) {
          return _toTrack(songs.first);
        }
      }
      return track;
    } catch (e) {
      return track;
    }
  }

  @override
  Future<String> getStreamUrl(Track track) async {
    try {
      final response = await _dio.post(
        '/api/song/enhance/player/url',
        data: {
          'ids': '[${track.id}]',
          'br': 320000,
        },
        options: Options(
          headers: {
            'Referer': 'https://music.163.com/',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        ),
      );

      final result = response.data;
      if (result is Map<String, dynamic> && result['code'] == 200) {
        final data = result['data'] as List<dynamic>? ?? [];
        if (data.isNotEmpty) {
          final url = data.first['url'] as String?;
          if (url != null && url.isNotEmpty) {
            return url;
          }
        }
      }
      throw Exception('无法获取播放地址，可能需要登录');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<String?> getLyrics(Track track) async {
    try {
      final response = await _dio.post(
        '/api/song/lyric',
        data: {
          'id': track.id,
          'lv': 1,
          'kv': 1,
          'tv': 1,
        },
        options: Options(
          headers: {
            'Referer': 'https://music.163.com/',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        ),
      );

      final result = response.data;
      if (result is Map<String, dynamic> && result['code'] == 200) {
        final lrc = result['lrc']?['lyric'] as String?;
        if (lrc != null && lrc.isNotEmpty) {
          return lrc;
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Track _toTrack(dynamic song) {
    final map = song as Map<String, dynamic>;
    final artists = (map['artists'] as List<dynamic>? ?? [])
        .map((a) => (a as Map<String, dynamic>)['name'] as String? ?? '')
        .join(' / ');
    final album = map['album'] as Map<String, dynamic>?;
    final duration = (map['duration'] as int?) ?? 0;

    return Track(
      id: (map['id'] as int).toString(),
      sourceId: sourceId,
      title: map['name'] as String? ?? '',
      artist: artists.isNotEmpty ? artists : '未知艺术家',
      album: album?['name'] as String?,
      duration: Duration(milliseconds: duration),
      coverUrl: album?['picUrl'] as String? ?? album?['blurPicUrl'] as String?,
      sourceData: map,
    );
  }
}
