import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:dio/dio.dart';

import 'netease_crypto.dart';

import '../../core/error/source_exception.dart';
import '../../core/model/track.dart';
import '../../core/network/source_auth_interceptor.dart';
import '../../core/source/music_source.dart';
import '../../features/auth/domain/auth_capability.dart';
import '../../features/auth/domain/auth_result.dart';
import '../../features/auth/domain/qr_login_poll.dart';
import '../../features/auth/domain/source_account.dart';
import '../../features/lyrics/domain/lrc_parser.dart';
import '../../features/lyrics/domain/lyric_bundle.dart';
import '../../features/lyrics/domain/yrc_parser.dart';

/// 网易云音乐渠道（Master Plan §5.2）。
///
/// 匿名能力：搜索 / 播放地址 / 详情 / 歌词；
/// 登录方式：MUSIC_U 纯值 Cookie（含输入清洗与获取指引）。
class NeteaseSource extends MusicSource {
  NeteaseSource({
    required super.credentialReader,
    this.onSessionExpired,
  });

  /// 渠道唯一标识与展示信息。
  static const String id = 'netease';

  /// 会话过期回调（由组合根接 AccountNotifier）。
  final void Function()? onSessionExpired;

  final Random _random = Random.secure();

  @override
  String get sourceId => NeteaseSource.id;

  @override
  String get displayName => '网易云音乐';

  @override
  AuthCapability get authCapability => const AuthCapability(
        type: AuthType.cookie,
        fields: [
          CredentialField(
            key: 'MUSIC_U',
            label: 'MUSIC_U',
            obscure: false,
            placeholder: '粘贴 MUSIC_U 的纯值',
            hint: '仅本机安全存储，永不明文上传',
          ),
        ],
        guide: AuthGuide(
          title: '如何获取 MUSIC_U',
          steps: [
            '在浏览器登录网页版网易云（music.163.com）。',
            '按 F12 打开开发者工具，切换到「应用 → Cookie」。',
            '找到名为 MUSIC_U 的条目并复制它的值（一长串字母数字）。',
            '回到本页粘贴该纯值即可登录；不要带上「MUSIC_U=」前缀。',
          ],
        ),
      );

  late final Dio _dio = _buildDio();

  Dio _buildDio() {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'https://music.163.com',
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 10),
        headers: <String, String>{
          'Referer': 'https://music.163.com',
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15',
        },
        validateStatus: (int? code) => code != null && code < 500,
      ),
    );
    dio.interceptors.add(
      SourceAuthInterceptor(
        sourceId: NeteaseSource.id,
        readCredentials: credentialReader,
        onSessionExpired: () => onSessionExpired?.call(),
      ),
    );
    return dio;
  }

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
      final response = await _dio.get<dynamic>(
        '/api/search/get/web',
        queryParameters: <String, dynamic>{
          'csrf_token': '',
          'hlpretag': '',
          'hlposttag': '',
          's': keyword,
          'type': 1,
          'offset': offset,
          'total': true,
          'limit': limit,
        },
        options: Options(responseType: ResponseType.plain),
      );
      final result = _asMap(_decoded(response)['result']);
      final songs = result?['songs'] as List<dynamic>?;
      if (songs == null) return const <Track>[];
      return songs
          .map(_trackFromSearchSong)
          .whereType<Track>()
          .toList(growable: false);
    } on DioException catch (e) {
      developer.log(
        'search 失败: type=${e.type} '
        'status=${e.response?.statusCode} msg=${e.message}',
        name: 'MusaicNetease',
      );
      throw NetworkSourceException('搜索失败：网络异常', sourceId: sourceId);
    }
  }

  @override
  Future<Track> getTrackDetail(Track track) async {
    final songId = _songIdOf(track);
    if (songId == null) return track;
    try {
      final response = await _dio.get<dynamic>(
        '/api/song/detail',
        queryParameters: <String, dynamic>{'ids': '[$songId]'},
        options: Options(responseType: ResponseType.plain),
      );
      final songs = _decoded(response)?['songs'] as List<dynamic>?;
      if (songs == null || songs.isEmpty) return track;
      final detail = _asMap(songs.first);
      if (detail == null) return track;
      final album = _asMap(detail['album']);
      return track.copyWith(
        album: (album?['name'] as String?) ?? track.album,
        coverUrl: (album?['picUrl'] as String?) ?? track.coverUrl,
        duration: detail['duration'] is int
            ? Duration(milliseconds: detail['duration'] as int)
            : track.duration,
      );
    } catch (_) {
      return track; // 详情失败不影响播放
    }
  }

  @override
  Future<ResolvedStream> resolveStream(Track track) async {
    final songId = _songIdOf(track);
    if (songId == null) {
      throw UnavailableStreamException('曲目缺少渠道标识', sourceId: sourceId);
    }
    try {
      final response = await _dio.get<dynamic>(
        '/api/song/enhance/player/url',
        queryParameters: <String, dynamic>{
          'ids': '[$songId]',
          'br': 320000,
          'csrf_token': '',
        },
        options: Options(responseType: ResponseType.plain),
      );
      final data = _asMap(_decoded(response))?['data'] as List<dynamic>?;
      if (data == null || data.isEmpty) {
        throw UnavailableStreamException('该曲目暂不可播放', sourceId: sourceId);
      }
      final item = _asMap(data.first);
      final url = item?['url'] as String?;
      final code = item?['code'] as int? ?? -1;
      if (url == null || url.isEmpty || code != 200) {
        throw UnavailableStreamException(
          '该曲目需要会员或暂不可用',
          sourceId: sourceId,
        );
      }
      // 强制 HTTPS（安全清单）
      final secureUrl = url.startsWith('http://')
          ? url.replaceFirst('http://', 'https://')
          : url;
      return ResolvedStream(
        url: secureUrl,
        headers: <String, String>{'Referer': 'https://music.163.com'},
      );
    } on DioException {
      throw NetworkSourceException('获取播放地址失败：网络异常',
          sourceId: sourceId);
    }
  }

  /// 歌词降级链：官方逐字(YRC+YTLRC 翻译) > LRC+TLYRIC > 无。
  /// TTML 解析器面向第三方渠道来源，本渠道不涉及。
  @override
  Future<LyricBundle?> fetchLyrics(Track track) async {
    final songId = _songIdOf(track);
    if (songId == null) return null;
    try {
      final response = await _dio.get<dynamic>(
        '/api/song/lyric',
        queryParameters: <String, dynamic>{
          'os': 'pc',
          'id': songId,
          'lv': -1,
          'kv': -1,
          'tv': -1,
          'rv': -1,
        },
        options: Options(responseType: ResponseType.plain),
      );
      final data = _asMap(_decoded(response));
      if (data == null) return null;

      final yrcText = _lyricText(data, 'yrc');
      if (yrcText != null) {
        final bundle = YrcParser.parse(yrcText);
        final ytlrcText = _lyricText(data, 'ytlrc');
        if (ytlrcText != null) {
          LyricBundle.mergeTranslations(
            base: bundle.lines,
            translations: YrcParser.parse(ytlrcText).lines,
            tolerance: const Duration(milliseconds: 300),
          );
        }
        return bundle.isEmpty ? null : bundle;
      }

      final lrcText = _lyricText(data, 'lrc');
      if (lrcText == null) return null;
      final bundle = LrcParser.parse(lrcText);
      final tlyricText = _lyricText(data, 'tlyric');
      if (tlyricText != null) {
        LyricBundle.mergeTranslations(
          base: bundle.lines,
          translations: LrcParser.parse(tlyricText).lines,
        );
      }
      return bundle.isEmpty ? null : bundle;
    } catch (_) {
      return null; // 歌词缺失不阻塞播放
    }
  }

  // ---------- 真实登录（weapi / 二维码） ----------

  /// 游客指纹 Cookie（对照 NeteaseCloudMusicApi request.js 校准）。
  /// weapi 登录类接口缺这些字段会返回空响应体。
  String _guestCookie() {
    final hex = List.generate(
      32,
      (_) => '0123456789abcdef'[_random.nextInt(16)],
    ).join();
    final ts = DateTime.now().millisecondsSinceEpoch;
    return <String, String>{
      '__remember_me': 'true',
      'ntes_kaola_ad': '1',
      '_ntes_nuid': hex,
      '_ntes_nnid': '$hex,$ts',
      'WEVNSM': '1.0.0',
      'osver':
          'Microsoft-Windows-10-Professional-build-22631-64bit',
      'deviceId': hex,
      'os': 'pc',
      'channel': 'netease',
      'appver': '3.0.18.203152',
    }.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 手机号 + 密码登录（weapi 加密真实请求）。
  /// 成功返回 [AuthSuccess]（含资料），凭据为 MUSIC_U。
  Future<AuthResult> loginByPhone(
    String phone,
    String password, {
    String countryCode = '86',
  }) async {
    final payload = <String, dynamic>{
      'type': '1',
      'https': 'true',
      'phone': phone,
      'countrycode': countryCode,
      'password': NeteaseCrypto.md5Hex(password),
      'rememberLogin': 'true',
      'csrf_token': '',
    };
    final (:params, :encSecKey) = NeteaseCrypto.encryptPayload(payload);
    try {
      final response = await _dio.post<dynamic>(
        '/weapi/w/login/cellphone',
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          headers: <String, String>{
            'Referer': 'https://music.163.com',
            'User-Agent':
                'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 '
                'Safari/537.36 Edg/124.0.0.0',
            'Cookie': _guestCookie(),
          },
        ),
        data: 'params=${Uri.encodeQueryComponent(params)}'
            '&encSecKey=${Uri.encodeQueryComponent(encSecKey)}',
      );
      final data = _asMap(_decoded(response));
      final code = data?['code'] as int? ?? -1;
      if (code != 200) {
        final message =
            data?['message'] as String? ?? data?['msg'] as String? ?? '';
        return AuthFailure(
          reason: AuthFailureReason.invalidCredentials,
          message: message.isEmpty ? '手机号或密码错误（code $code）' : message,
        );
      }
      final musicU = _extractMusicU(response) ??
          _musicUFromBodyCookie(data?['cookie'] as String?);
      if (musicU == null || musicU.isEmpty) {
        return const AuthFailure(
          reason: AuthFailureReason.serverError,
          message: '登录成功但未返回凭据，请重试',
        );
      }
      final profile = _asMap(data?['profile']);
      final nickname = profile?['nickname'] as String? ?? '';
      return AuthSuccess(
        SourceAccount.markNow(
          sourceId: sourceId,
          status: AccountStatus.loggedIn,
          userId: profile?['userId']?.toString(),
          nickname: nickname.isEmpty ? '网易云用户' : nickname,
          avatarUrl: profile?['avatarUrl'] as String?,
        ),
        credentials: {'MUSIC_U': musicU},
      );
    } on DioException {
      return const AuthFailure(
        reason: AuthFailureReason.network,
        message: '网络异常，请稍后重试',
      );
    }
  }

  /// 创建二维码登录会话：返回 [key]（unikey）与二维码内容 URL。
  Future<({String key, String qrContent})> createQrLogin() async {
    final Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        '/api/login/qrcode/unikey',
        data: {'type': 1},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
        ),
      );
    } on DioException catch (e) {
      developer.log(
        'createQrLogin DioException: type=${e.type} '
        'status=${e.response?.statusCode} msg=${e.message} '
        'error=${e.error}',
        name: 'MusaicNetease',
      );
      rethrow;
    }
    developer.log(
      'createQrLogin status=${response.statusCode} '
      'body=${response.data}',
      name: 'MusaicNetease',
    );
    final data = _asMap(_decoded(response));
    final key = data?['unikey'] as String? ?? '';
    if (key.isEmpty) {
      throw NetworkSourceException('获取登录二维码失败', sourceId: sourceId);
    }
    return (
      key: key,
      qrContent: 'https://music.163.com/login?codekey=$key',
    );
  }

  /// 轮询二维码状态。
  Future<QrLoginPoll> pollQrLogin(String key) async {
    final response = await _dio.get<dynamic>(
      '/api/login/qrcode/client/login',
      queryParameters: <String, dynamic>{'key': key, 'type': 1},
      options: Options(responseType: ResponseType.plain),
    );
    final data = _asMap(_decoded(response));
    final code = data?['code'] as int? ?? -1;
    switch (code) {
      case 800:
        return QrLoginPoll.expired();
      case 802:
        return QrLoginPoll.scanned();
      case 803:
        final musicU = _musicUFromBodyCookie(
          data?['cookie'] as String? ?? '',
        );
        String? nickname;
        if (musicU != null && musicU.isNotEmpty) {
          try {
            final profile =
                await _fetchProfile(cookie: 'MUSIC_U=$musicU');
            nickname = profile?['nickname'] as String?;
          } catch (_) {}
        }
        return QrLoginPoll.success(
          credentials: <String, String>{'MUSIC_U': musicU ?? ''},
          nickname: nickname,
        );
      default:
        return QrLoginPoll.waiting();
    }
  }

  /// 当前登录账号的用户歌单（登录后调用）。
  Future<List<NeteaseUserPlaylist>> fetchUserPlaylists(String uid) async {
    final response = await _dio.get<dynamic>(
      '/api/user/playlist',
      queryParameters: <String, dynamic>{'uid': uid, 'limit': 100},
      options: Options(responseType: ResponseType.plain),
    );
    final list =
        _asMap(_decoded(response))?['playlist'] as List<dynamic>?;
    if (list == null) return const <NeteaseUserPlaylist>[];
    return list
        .map(_parseUserPlaylist)
        .whereType<NeteaseUserPlaylist>()
        .toList(growable: false);
  }

  NeteaseUserPlaylist? _parseUserPlaylist(dynamic raw) {
    final p = _asMap(raw);
    if (p == null) return null;
    final id = p['id'] as int?;
    final name = p['name'] as String?;
    if (id == null || name == null) return null;
    return NeteaseUserPlaylist(
      id: id,
      name: name,
      trackCount: p['trackCount'] as int? ?? 0,
      coverUrl: p['coverImgUrl'] as String?,
      playCount: p['playCount'] as int? ?? 0,
    );
  }

  /// 歌单详情 → 统一曲目列表（登录 Cookie 越权可见 VIP 曲目信息）。
  Future<List<Track>> fetchPlaylistTracks(int playlistId) async {
    final response = await _dio.get<dynamic>(
      '/api/playlist/detail',
      queryParameters: <String, dynamic>{'id': playlistId},
      options: Options(responseType: ResponseType.plain),
    );
    final tracks =
        _asMap(_asMap(_decoded(response))?['result'])?['tracks']
            as List<dynamic>?;
    if (tracks == null) return const <Track>[];
    return tracks.map(_trackFromDetailSong).whereType<Track>().toList();
  }

  Track? _trackFromDetailSong(dynamic raw) {
    final song = _asMap(raw);
    if (song == null) return null;
    final songId = song['id'] as int?;
    final name = song['name'] as String?;
    if (songId == null || name == null) return null;
    final artists = (song['artists'] as List<dynamic>? ?? const <dynamic>[])
        .map((a) => _asMap(a)?['name'] as String?)
        .whereType<String>()
        .join('/');
    final album = _asMap(song['album']);
    final durationMs = song['duration'] as int?;
    return Track(
      id: '$songId',
      sourceId: NeteaseSource.id,
      title: name,
      artist: artists.isEmpty ? '未知歌手' : artists,
      album: album?['name'] as String?,
      duration:
          durationMs == null ? null : Duration(milliseconds: durationMs),
      coverUrl: album?['picUrl'] as String?,
      sourceData: <String, dynamic>{'neteaseId': songId},
    );
  }

  String? _extractMusicU(Response<dynamic> response) {
    final cookies = response.headers['set-cookie'];
    if (cookies == null) return null;
    for (final cookie in cookies) {
      final match = RegExp(r'MUSIC_U=([^;]+)').firstMatch(cookie);
      if (match != null) return match.group(1);
    }
    return null;
  }

  String? _musicUFromBodyCookie(String? cookie) {
    if (cookie == null) return null;
    final match = RegExp(r'MUSIC_U=([^;]+)').firstMatch(cookie);
    return match?.group(1);
  }

  // ---------- 账号能力 ----------

  @override
  Future<AuthResult> login(Map<String, String> credentials) async {
    final cookieValue =
        credentials['MUSIC_U']?.trim().replaceAll('\n', '') ?? '';
    if (cookieValue.isEmpty) {
      return const AuthFailure(
        reason: AuthFailureReason.invalidCredentials,
        message: '请输入 MUSIC_U 纯值',
      );
    }
    try {
      final profile = await _fetchProfile(cookie: 'MUSIC_U=$cookieValue');
      final nickname = profile?['nickname'] as String?;
      if (profile == null || nickname == null || nickname.isEmpty) {
        return const AuthFailure(
          reason: AuthFailureReason.invalidCredentials,
          message: 'Cookie 无效或已过期，请重新获取',
        );
      }
      return AuthSuccess(
        SourceAccount.markNow(
          sourceId: sourceId,
          status: AccountStatus.loggedIn,
          userId: profile['userId']?.toString(),
          nickname: nickname,
          avatarUrl: profile['avatarUrl'] as String?,
        ),
        credentials: {'MUSIC_U': cookieValue},
      );
    } on DioException {
      return const AuthFailure(
        reason: AuthFailureReason.network,
        message: '网络异常，请稍后重试',
      );
    }
  }

  @override
  Future<bool> checkSession() async {
    try {
      final credentials = await credentialReader();
      final musicU = credentials['MUSIC_U'];
      if (musicU == null || musicU.isEmpty) return false;
      final profile = await _fetchProfile(cookie: 'MUSIC_U=$musicU');
      return profile != null &&
          ((profile['nickname'] as String?)?.isNotEmpty ?? false);
    } catch (_) {
      return false;
    }
  }

  // ---------- 工具 ----------

  /// 统一解码响应体：老接口返回的 Content-Type 常不是 application/json，
  /// Dio 会把 JSON 正文留成 String，这里手动解码兜底。
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

  String? _lyricText(Map<String, dynamic> data, String key) {
    final value = _asMap(data[key])?['lyric'] as String?;
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  Future<Map<String, dynamic>?> _fetchProfile({
    required String cookie,
  }) async {
    final response = await _dio.get<dynamic>(
      '/api/nuser/account/get',
      options: Options(
        headers: <String, String>{'Cookie': cookie},
        responseType: ResponseType.plain,
      ),
    );
    final data = _asMap(_decoded(response));
    if (data == null || (data['code'] as int? ?? -1) != 200) return null;
    return _asMap(data['profile']);
  }

  int? _songIdOf(Track track) =>
      (track.sourceData?['neteaseId'] as num?)?.toInt() ??
      int.tryParse(track.id);

  Track? _trackFromSearchSong(dynamic raw) {
    final song = _asMap(raw);
    if (song == null) return null;
    final songId = song['id'] as int?;
    final name = song['name'] as String?;
    if (songId == null || name == null) return null;
    final artists = (song['artists'] as List<dynamic>? ?? const <dynamic>[])
        .map((a) => _asMap(a)?['name'] as String?)
        .whereType<String>()
        .join('/');
    final album = _asMap(song['album']);
    final durationMs = song['duration'] as int?;
    return Track(
      id: '$songId',
      sourceId: NeteaseSource.id,
      title: name,
      artist: artists.isEmpty ? '未知歌手' : artists,
      album: album?['name'] as String?,
      duration:
          durationMs == null ? null : Duration(milliseconds: durationMs),
      coverUrl: album?['picUrl'] as String?,
      sourceData: <String, dynamic>{'neteaseId': songId},
    );
  }

  Map<String, dynamic>? _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;
}

/// 网易云用户歌单（账号歌单）。
class NeteaseUserPlaylist {
  const NeteaseUserPlaylist({
    required this.id,
    required this.name,
    required this.trackCount,
    required this.playCount,
    this.coverUrl,
  });

  final int id;
  final String name;
  final int trackCount;
  final int playCount;
  final String? coverUrl;
}
