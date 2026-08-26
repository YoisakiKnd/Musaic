import 'package:dio/dio.dart';

import '../../core/error/source_exception.dart';
import '../../core/model/track.dart';
import '../../core/source/music_source.dart';
import '../../features/auth/domain/auth_capability.dart';
import '../../features/auth/domain/auth_result.dart';
import '../../features/lyrics/domain/lyric_bundle.dart';

/// YouTube Music 渠道（V1 匿名能力：搜索 / 播放直链）。
///
/// 基于 InnerTube 公开接口：
/// - 搜索：WEB_REMIX 客户端 + 歌曲过滤 params
/// - 播放：ANDROID_MUSIC 客户端 player 接口（多数曲目返回免签名的
///   googlevideo 直链；带 signatureCipher 的受限曲目暂不支持）
/// - 歌词：V1 暂不提供（字幕接口后续版本接入）
///
/// 注意：该渠道要求设备可直连 YouTube（在受限网络下需系统代理环境）。
class YouTubeMusicSource extends MusicSource {
  YouTubeMusicSource({required super.credentialReader});

  static const String id = 'ytmusic';

  @override
  String get sourceId => YouTubeMusicSource.id;

  @override
  String get displayName => 'YouTube Music';

  @override
  AuthCapability get authCapability => AuthCapability.noAuth;

  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Origin': 'https://music.youtube.com',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
      },
      validateStatus: (int? code) => code != null && code < 500,
    ),
  );

  static const String _webRemixVersion = '1.20240401.01.00';
  static const String _androidMusicVersion = '6.42.52';
  static const String _songsFilterParams =
      'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D';

  Map<String, dynamic> _webRemixContext() => <String, dynamic>{
        'client': <String, dynamic>{
          'clientName': 'WEB_REMIX',
          'clientVersion': _webRemixVersion,
          'hl': 'zh-CN',
          'gl': 'US',
        },
      };

  Map<String, dynamic> _androidMusicContext() => <String, dynamic>{
        'client': <String, dynamic>{
          'clientName': 'ANDROID_MUSIC',
          'clientVersion': _androidMusicVersion,
          'androidSdkVersion': 30,
          'hl': 'zh-CN',
          'gl': 'US',
        },
      };

  // ---------- 音乐能力 ----------

  @override
  Future<List<Track>> search(
    String query, {
    int limit = 30,
    int offset = 0,
  }) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const <Track>[];
    try {
      final response = await _dio.post<dynamic>(
        'https://music.youtube.com/youtubei/v1/search',
        queryParameters: const <String, dynamic>{'prettyPrint': false},
        options: Options(
          headers: <String, String>{
            'X-YouTube-Client-Name': '67',
            'X-YouTube-Client-Version': _webRemixVersion,
          },
        ),
        data: <String, dynamic>{
          'context': _webRemixContext(),
          'query': keyword,
          'params': _songsFilterParams,
        },
      );
      final results = _extractSongs(_asMap(response.data));
      return results.take(limit).toList(growable: false);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout) {
        throw NetworkSourceException(
          '无法连接 YouTube Music：请确认设备可访问 YouTube（受限网络需系统代理）',
          sourceId: sourceId,
        );
      }
      throw NetworkSourceException('搜索失败：网络异常', sourceId: sourceId);
    }
  }

  @override
  Future<Track> getTrackDetail(Track track) async => track;

  @override
  Future<ResolvedStream> resolveStream(Track track) async {
    final videoId = track.sourceData?['videoId'] as String? ?? track.id;
    if (videoId.isEmpty) {
      throw UnavailableStreamException('曲目缺少渠道标识', sourceId: sourceId);
    }
    try {
      final response = await _dio.post<dynamic>(
        'https://music.youtube.com/youtubei/v1/player',
        queryParameters: const <String, dynamic>{'prettyPrint': false},
        options: Options(
          headers: <String, String>{
            'User-Agent':
                'com.google.android.apps.youtube.music/$_androidMusicVersion (Linux; U; Android 11) gzip',
            'X-YouTube-Client-Name': '21',
            'X-YouTube-Client-Version': _androidMusicVersion,
          },
        ),
        data: <String, dynamic>{
          'context': _androidMusicContext(),
          'videoId': videoId,
          'contentCheckOk': true,
          'racyCheckOk': true,
        },
      );
      final root = _asMap(response.data);
      final playability =
          _asMap(root?['playabilityStatus'])?['status'] as String?;
      if (playability != 'OK') {
        final reason =
            _asMap(root?['playabilityStatus'])?['reason'] as String? ??
                '不可播放';
        throw UnavailableStreamException(reason, sourceId: sourceId);
      }
      final streamingData = _asMap(root?['streamingData']);
      final formats = <(int, String)>[]; // (bitrate, url) 仅音频
      for (final key in const ['adaptiveFormats', 'formats']) {
        final list = streamingData?[key] as List<dynamic>?;
        if (list == null) continue;
        for (final raw in list) {
          final f = _asMap(raw);
          final mime = f?['mimeType'] as String? ?? '';
          final url = f?['url'] as String?;
          final bitrate = f?['bitrate'] as int? ?? 0;
          if (url != null && url.isNotEmpty && mime.startsWith('audio/')) {
            formats.add((bitrate, url));
          }
        }
        if (formats.isNotEmpty) break; // 优先 adaptiveFormats
      }
      if (formats.isEmpty) {
        throw UnavailableStreamException(
          '该曲目需要签名解码支持，暂不可播放',
          sourceId: sourceId,
        );
      }
      formats.sort((a, b) => b.$1.compareTo(a.$1)); // 最高码率优先
      return ResolvedStream(url: formats.first.$2);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout) {
        throw NetworkSourceException(
          '无法连接 YouTube Music：请确认设备可访问 YouTube（受限网络需系统代理）',
          sourceId: sourceId,
        );
      }
      throw NetworkSourceException('获取播放地址失败：网络异常',
          sourceId: sourceId);
    }
  }

  @override
  Future<LyricBundle?> fetchLyrics(Track track) async => null;

  // ---------- 账号能力 ----------

  @override
  Future<AuthResult> login(Map<String, String> credentials) async =>
      const AuthFailure(
        reason: AuthFailureReason.unsupported,
        message: 'YouTube Music 匿名模式无需登录',
      );

  // ---------- 解析 ----------

  List<Track> _extractSongs(Map<String, dynamic>? root) {
    final results = <Track>[];
    final contents = _path(root, [
      'contents',
      'tabbedSearchResultsRenderer',
      'tabs',
    ]) as List<dynamic>?;
    final tabContent = _asMap(_asList(contents)?.firstOrNull?['tabRenderer'])
        ?['content'];
    final sections =
        _asMap(tabContent)?['sectionListRenderer']?['contents']
            as List<dynamic>?;
    for (final section in sections ?? const <dynamic>[]) {
      final shelf = _asMap(_asMap(section)?['musicShelfRenderer']);
      final items = shelf?['contents'] as List<dynamic>?;
      for (final item in items ?? const <dynamic>[]) {
        final track = _parseListItem(_asMap(item));
        if (track != null) results.add(track);
      }
    }
    return results;
  }

  Track? _parseListItem(Map<String, dynamic>? item) {
    if (item == null) return null;
    final videoId = _path(item, [
      'playlistItemData',
      'videoId',
    ]) as String?;
    if (videoId == null || videoId.isEmpty) return null;

    final flexColumns =
        item['flexColumns'] as List<dynamic>? ?? const <dynamic>[];
    String title = '';
    final artists = <String>[];
    String? album;
    Duration? duration;

    for (var i = 0; i < flexColumns.length; i++) {
      final runs = _path(_asMap(flexColumns[i]), [
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
      ]) as List<dynamic>?;
      if (runs == null || runs.isEmpty) continue;
      if (i == 0) {
        title = _asMap(runs.first)?['text'] as String? ?? '';
        continue;
      }
      for (final rawRun in runs) {
        final run = _asMap(rawRun);
        final text = run?['text'] as String? ?? '';
        final watch =
            _path(run, ['navigationEndpoint', 'watchEndpoint']);
        final pageType = _path(run, [
          'navigationEndpoint',
          'watchEndpoint',
          'watchEndpointMusicSupportedConfigs',
          'watchEndpointMusicConfig',
          'musicVideoType',
        ]);
        if (watch != null) {
          // 专辑或歌曲跳转：ATM_VIDEO / album 页面类型视为专辑名
          if (pageType == 'MUSIC_PAGE_TYPE_ALBUM') album = text;
        } else if (RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$').hasMatch(text)) {
          duration = _parseDuration(text);
        } else if (text.trim().isNotEmpty) {
          artists.add(text.trim());
        }
      }
    }
    if (title.isEmpty) return null;

    final thumbs = _path(item, [
      'thumbnail',
      'musicThumbnailRenderer',
      'thumbnail',
      'thumbnails',
    ]) as List<dynamic>?;
    String? coverUrl;
    if (thumbs != null && thumbs.isNotEmpty) {
      coverUrl = _asMap(thumbs.last)?['url'] as String?;
    }

    return Track(
      id: videoId,
      sourceId: sourceId,
      title: title,
      artist: artists.isEmpty ? 'Unknown Artist' : artists.join('/'),
      album: album,
      duration: duration,
      coverUrl: coverUrl,
      sourceData: <String, dynamic>{'videoId': videoId},
    );
  }

  Duration? _parseDuration(String text) {
    final parts = text.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]);
      final s = int.tryParse(parts[1]);
      if (m != null && s != null) return Duration(minutes: m, seconds: s);
    } else if (parts.length == 3) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final s = int.tryParse(parts[2]);
      if (h != null && m != null && s != null) {
        return Duration(hours: h, minutes: m, seconds: s);
      }
    }
    return null;
  }

  dynamic _path(Map<String, dynamic>? map, List<String> keys) {
    dynamic current = map;
    for (final key in keys) {
      if (current is! Map) return null;
      current = current[key];
    }
    return current;
  }

  List<dynamic>? _asList(dynamic value) =>
      value is List ? value : null;

  Map<String, dynamic>? _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
