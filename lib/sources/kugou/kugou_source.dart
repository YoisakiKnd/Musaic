import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/error/source_exception.dart';
import '../../core/model/track.dart';
import '../../core/source/music_source.dart';
import '../../features/auth/domain/auth_capability.dart';
import '../../features/auth/domain/auth_result.dart';
import '../../features/lyrics/domain/lrc_parser.dart';
import '../../features/lyrics/domain/lyric_bundle.dart';

/// 酷狗音乐渠道（V1 匿名能力：搜索 / 播放直链 / LRC 歌词）。
///
/// - 搜索：songsearch.kugou.com 公开检索
/// - 播放：m.kugou.com playInfo 匿名直链（非 VIP 曲目 128k）
/// - 歌词：krcs.kugou.com LRC（KRC 逐字格式需解密，后续版本支持）
/// 账号 Cookie 登录（VIP 试听完整版）预留后续版本。
class KugouSource extends MusicSource {
  KugouSource({required super.credentialReader});

  static const String id = 'kugou';

  @override
  String get sourceId => KugouSource.id;

  @override
  String get displayName => '酷狗音乐';

  @override
  AuthCapability get authCapability => AuthCapability.noAuth;

  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      headers: <String, String>{
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
      },
      validateStatus: (int? code) => code != null && code < 500,
    ),
  );

  // ---------- 音乐能力 ----------

  @override
  Future<List<Track>> search(
    String query, {
    int limit = 30,
    int offset = 0,
  }) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const <Track>[];
    final page = (offset ~/ (limit == 0 ? 30 : limit)) + 1;
    try {
      final response = await _dio.get<dynamic>(
        'https://songsearch.kugou.com/song_search_v2',
        queryParameters: <String, dynamic>{
          'keyword': keyword,
          'page': page,
          'pagesize': limit,
          'filter': 0,
          'platform': 'WebFilter',
        },
      );
      final lists = _asMap(_asMap(_decoded(response))?['data'])?['lists']
          as List<dynamic>?;
      if (lists == null) return const <Track>[];
      return lists
          .map(_trackFromSearchSong)
          .whereType<Track>()
          .toList(growable: false);
    } on DioException {
      throw NetworkSourceException('搜索失败：网络异常', sourceId: sourceId);
    }
  }

  @override
  Future<Track> getTrackDetail(Track track) async => track;

  @override
  Future<ResolvedStream> resolveStream(Track track) async {
    final hash = track.sourceData?['hash'] as String?;
    if (hash == null || hash.isEmpty) {
      throw UnavailableStreamException('曲目缺少渠道标识', sourceId: sourceId);
    }
    try {
      final response = await _dio.get<dynamic>(
        'https://m.kugou.com/app/i/getSongInfo.php',
        queryParameters: <String, dynamic>{
          'cmd': 'playInfo',
          'hash': hash,
        },
      );
      final data = _asMap(_decoded(response));
      final status = data?['status'] as int? ?? -1;
      final url = data?['url'] as String?;
      if (status != 1 || url == null || url.isEmpty) {
        throw UnavailableStreamException(
          '该曲目需要版权授权，暂不可播放',
          sourceId: sourceId,
        );
      }
      return ResolvedStream(url: url, isLocalFile: false);
    } on DioException {
      throw NetworkSourceException('获取播放地址失败：网络异常',
          sourceId: sourceId);
    }
  }

  @override
  Future<LyricBundle?> fetchLyrics(Track track) async {
    final hash = track.sourceData?['hash'] as String?;
    if (hash == null || hash.isEmpty) return null;
    try {
      // 1) hash → 歌词候选
      final search = await _dio.get<dynamic>(
        'https://krcs.kugou.com/search',
        queryParameters: <String, dynamic>{
          'ver': 1,
          'man': 'yes',
          'client': 'mobi',
          'keyword': '',
          'duration': '',
          'hash': hash,
        },
      );
      final candidates =
          _asMap(_decoded(search))?['candidates'] as List<dynamic>?;
      if (candidates == null || candidates.isEmpty) return null;
      final first = _asMap(candidates.first);
      final lyricId = first?['id'] as String?;
      final accessKey = first?['accesskey'] as String?;
      if (lyricId == null || accessKey == null) return null;

      // 2) 下载 LRC
      final download = await _dio.get<dynamic>(
        'https://krcs.kugou.com/download',
        queryParameters: <String, dynamic>{
          'ver': 1,
          'client': 'mobi',
          'fmt': 'lrc',
          'charset': 'utf8',
          'id': lyricId,
          'accesskey': accessKey,
        },
      );
      final content =
          _asMap(_decoded(download))?['content'] as String?;
      if (content == null || content.trim().isEmpty) return null;
      final bundle = LrcParser.parse(content);
      return bundle.isEmpty ? null : bundle;
    } catch (_) {
      return null;
    }
  }

  // ---------- 账号能力 ----------

  @override
  Future<AuthResult> login(Map<String, String> credentials) async =>
      const AuthFailure(
        reason: AuthFailureReason.unsupported,
        message: '酷狗音乐匿名模式无需登录（账号登录将在后续版本提供）',
      );

  // ---------- 工具 ----------

  Track? _trackFromSearchSong(dynamic raw) {
    final song = _asMap(raw);
    if (song == null) return null;
    final hash = song['FileHash'] as String?;
    if (hash == null || hash.isEmpty) return null;
    String cleanName(String rawName) => rawName
        .replaceAll('<em>', '')
        .replaceAll('</em>', '')
        .trim();
    final name = cleanName(song['SongName'] as String? ?? '');
    if (name.isEmpty) return null;
    final singer = (song['SingerName'] as String? ?? '').trim();
    final image = song['Image'] as String?;
    final durationSec = song['Duration'] as int?;
    final albumId = song['AlbumID'] as String?;
    final coverUrl = (image == null || image.isEmpty)
        ? null
        : image.replaceAll('{size}', '240');
    return Track(
      id: hash,
      sourceId: sourceId,
      title: name,
      artist: singer.isEmpty ? '未知歌手' : singer,
      album: (song['AlbumName'] as String? ?? '').trim(),
      duration:
          durationSec == null ? null : Duration(seconds: durationSec),
      coverUrl: coverUrl,
      sourceData: <String, dynamic>{
        'hash': hash,
        if (albumId != null) 'albumId': albumId,
      },
    );
  }

  dynamic _decoded(Response<dynamic> response) {
    final data = response.data;
    if (data is String) {
      final trimmed = data.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          return jsonDecode(trimmed);
        } catch (_) {
          return null;
        }
      }
      return null;
    }
    return data;
  }

  Map<String, dynamic>? _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;
}
