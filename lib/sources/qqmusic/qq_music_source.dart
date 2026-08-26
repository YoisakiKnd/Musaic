import 'dart:convert';

import 'package:dio/dio.dart';
import '../../core/error/source_exception.dart';
import '../../core/model/track.dart';
import '../../core/source/music_source.dart';
import '../../features/auth/domain/auth_capability.dart';
import '../../features/auth/domain/auth_result.dart';
import '../../features/lyrics/domain/lrc_parser.dart';
import '../../features/lyrics/domain/lyric_bundle.dart';

/// QQ 音乐渠道（V1 匿名能力：搜索 / 播放直链 / LRC 歌词）。
///
/// - 搜索：c.y.qq.com 公开检索接口
/// - 播放：musicu.fly 的 vkey 匿名直链（非 VIP 曲目 128k/320k）
/// - 歌词：fcg_query_lyric_new（base64 LRC + 翻译）
/// Cookie 登录（绿钻权益）预留后续版本。
class QqMusicSource extends MusicSource {
  QqMusicSource({required super.credentialReader});

  static const String id = 'qqmusic';

  @override
  String get sourceId => QqMusicSource.id;

  @override
  String get displayName => 'QQ 音乐';

  @override
  AuthCapability get authCapability => AuthCapability.noAuth;

  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      headers: <String, String>{
        'Referer': 'https://y.qq.com/',
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15',
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
    try {
      // smartbox 联想搜索：当前唯一稳定可用的匿名检索入口（≤10 条）
      final response = await _dio.get<dynamic>(
        'https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg',
        queryParameters: <String, dynamic>{
          'key': keyword,
          'format': 'json',
        },
      );
      final songs = _asMap(_asMap(_asMap(_decoded(response))?['data'])?['song'])
          ?['itemlist'] as List<dynamic>?;
      if (songs == null) return const <Track>[];
      return songs
          .map(_trackFromSmartboxItem)
          .whereType<Track>()
          .toList(growable: false);
    } on DioException {
      throw NetworkSourceException('搜索失败：网络异常', sourceId: sourceId);
    }
  }

  @override
  Future<Track> getTrackDetail(Track track) async =>
      track; // 搜索结果已含全部展示字段

  @override
  Future<ResolvedStream> resolveStream(Track track) async {
    // 官方已对匿名 vkey 接口加设备指纹风控（code 500003），
    // 匿名播放暂不可用；Cookie 登录后走 musicu.fcg 解锁（后续版本）。
    throw UnavailableStreamException(
      'QQ 音乐匿名播放已被官方限制，请等待 Cookie 登录支持',
      sourceId: sourceId,
    );
  }

  @override
  Future<LyricBundle?> fetchLyrics(Track track) async {
    final songMid = track.sourceData?['songmid'] as String?;
    if (songMid == null || songMid.isEmpty) return null;
    try {
      final response = await _dio.get<dynamic>(
        'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg',
        queryParameters: <String, dynamic>{
          'songmid': songMid,
          'g_tk': 5381,
          'loginUin': 0,
          'format': 'json',
        },
      );
      final data = _asMap(_decoded(response));
      final lyricB64 = data?['lyric'] as String?;
      if (lyricB64 == null || lyricB64.isEmpty) return null;
      final lrcText = utf8.decode(base64.decode(lyricB64));
      final bundle = LrcParser.parse(lrcText);

      final transB64 = data?['trans'] as String?;
      if (transB64 != null && transB64.isNotEmpty) {
        try {
          final transText = utf8.decode(base64.decode(transB64));
          LyricBundle.mergeTranslations(
            base: bundle.lines,
            translations: LrcParser.parse(transText).lines,
          );
        } catch (_) {}
      }
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
        message: 'QQ 音乐匿名模式无需登录（Cookie 登录将在后续版本提供）',
      );

  // ---------- 工具 ----------

  Track? _trackFromSmartboxItem(dynamic raw) {
    final item = _asMap(raw);
    if (item == null) return null;
    final mid = item['mid'] as String?;
    final name = item['name'] as String?;
    if (mid == null || mid.isEmpty || name == null || name.isEmpty) {
      return null;
    }
    return Track(
      id: mid,
      sourceId: sourceId,
      title: name,
      artist:
          (item['singer'] as String? ?? '').trim().isEmpty
              ? '未知歌手'
              : (item['singer'] as String).trim(),
      sourceData: <String, dynamic>{'songmid': mid},
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
      // QQ 接口偶发 jsonp 包裹：去掉回调函数名
      final jsonpMatch =
          RegExp(r'^[^(]*\((.*)\);?\s*$', dotAll: true).firstMatch(trimmed);
      if (jsonpMatch != null) {
        try {
          return jsonDecode(jsonpMatch.group(1)!);
        } catch (_) {}
      }
      return null;
    }
    return data;
  }

  Map<String, dynamic>? _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;
}
