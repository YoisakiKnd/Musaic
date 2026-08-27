import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:dio/dio.dart';

import 'netease_crypto.dart';

import '../../core/error/source_exception.dart';
import '../../core/utils/url_utils.dart';
import '../../core/model/remote_playlist.dart';
import '../../core/model/track.dart';
import '../../core/network/source_auth_interceptor.dart';
import '../../core/source/capabilities.dart';
import '../../core/source/music_source.dart';
import '../../core/auth/auth_capability.dart';
import '../../core/auth/auth_result.dart';
import '../../core/auth/qr_login_poll.dart';
import '../../core/auth/source_account.dart';
import '../../core/lyrics/lrc_parser.dart';
import '../../core/lyrics/lyric_bundle.dart';
import '../../core/lyrics/yrc_parser.dart';

/// 网易云音乐渠道（Master Plan §5.2）。
///
/// 匿名能力：搜索 / 播放地址 / 详情 / 歌词；
/// 登录方式：二维码扫码（[QrLoginCapable]）、手机号密码
/// （[PasswordLoginCapable]）、MUSIC_U 纯值 Cookie 声明式表单兜底；
/// 登录后提供账号歌单（[RemotePlaylistCapable]）。
class NeteaseSource extends MusicSource
    implements QrLoginCapable, PasswordLoginCapable, RemotePlaylistCapable {
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
  bool get preferredByDefault => true;

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
        // 分级提示：未登录引导登录；已登录则说明版权/会员限制
        final loggedIn = await _hasCredentials();
        throw UnavailableStreamException(
          loggedIn
              ? '受版权方限制，该曲目暂不可播放（可能需要黑胶会员）'
              : '该曲目为会员/版权曲目，请先在「设置 → 账号管理」登录后尝试播放',
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

  /// 扫码登录流水线（供通用扫码页消费，UI 不感知网易云细节）。
  @override
  List<QrLoginFlow> get qrLoginFlows => [
        QrLoginFlow(
          id: 'qr',
          label: '二维码登录',
          scanHint: '请使用网易云音乐 App 扫码',
          interval: const Duration(seconds: 2),
          create: () async {
            final session = await createQrLogin();
            return QrLoginSession(
              pollKey: session.key,
              contentUrl: session.qrContent,
            );
          },
          poll: (session) => pollQrLogin(session.pollKey),
          fallbackNickname: '网易云用户',
          footerHint: '扫码登录后可播放 VIP 曲目并同步账号歌单',
        ),
      ];

  /// 手机号密码登录表单声明（通用登录页消费）。
  @override
  String get passwordTabLabel => '手机号登录';

  @override
  List<CredentialField> get passwordFields => const [
        CredentialField(key: 'phone', label: '手机号', numeric: true, placeholder: '11 位手机号'),
        CredentialField(key: 'password', label: '密码', obscure: true),
      ];

  @override
  String get passwordSubmitHint => '密码经 weapi 标准加密后提交，本机不保存明文';

  @override
  Future<AuthResult> loginWithPassword(Map<String, String> values) =>
      loginByPhone(values['phone'] ?? '', values['password'] ?? '');

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
  ///
  /// 803 授权成功：MUSIC_U 可能出现在 Set-Cookie 头或响应体 cookie 字段，
  /// 两路都取，避免只读 body 漏凭据导致「扫码后无动静」。
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
        final musicU = _extractMusicU(response) ??
            _musicUFromBodyCookie(data?['cookie'] as String? ?? '');
        developer.log(
          '二维码授权成功：musicU=${musicU == null ? '缺失' : '已取得(${musicU.length}字符)'}',
          name: 'MusaicNetease',
        );
        if (musicU == null || musicU.isEmpty) {
          throw NetworkSourceException(
            '授权成功但未取得登录凭据，请重试',
            sourceId: sourceId,
          );
        }
        String? nickname;
        try {
          final info = await fetchAccountSummary(cookie: 'MUSIC_U=$musicU');
          nickname = info?.nickname;
        } catch (_) {}
        return QrLoginPoll.success(
          credentials: <String, String>{'MUSIC_U': musicU},
          nickname: nickname,
        );
      default:
        developer.log('二维码轮询 code=$code', name: 'MusaicNetease');
        return QrLoginPoll.waiting();
    }
  }

  /// 拉取网易云账号昵称与会员状态（黑胶/VIP）。
  ///
  /// [cookie] 缺省时从安全存储读取。
  Future<({String nickname, String? vipLabel})?> fetchAccountSummary({
    String? cookie,
  }) async {
    String cookieHeader = cookie ?? '';
    if (cookieHeader.isEmpty) {
      final credentials = await credentialReader();
      final musicU = credentials['MUSIC_U'] ?? '';
      if (musicU.isEmpty) return null;
      cookieHeader = 'MUSIC_U=$musicU';
    }
    final profile = await _fetchProfile(cookie: cookieHeader);
    final nickname = profile?['nickname'] as String?;
    if (profile == null || nickname == null || nickname.isEmpty) {
      return null;
    }

    // 会员状态：weapi openvip v2（vipType 10=VIP 20/40=黑胶 11=学生）
    String? vipLabel;
    try {
      final (:params, :encSecKey) =
          NeteaseCrypto.encryptPayload(<String, dynamic>{'csrf_token': ''});
      final vipResp = await _dio.post<dynamic>(
        '/weapi/openvip/v2/info',
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          headers: <String, String>{'Cookie': cookieHeader},
        ),
        data: 'params=${Uri.encodeQueryComponent(params)}'
            '&encSecKey=${Uri.encodeQueryComponent(encSecKey)}',
      );
      final vipData = _asMap(_decoded(vipResp))?['data'];
      final redPlus = _asMap(vipData)?['redplus'];
      final vipType = _asMap(redPlus)?['vipType'] as int? ??
          _asMap(vipData)?['vipType'] as int? ??
          0;
      final level = _asMap(redPlus)?['redVipLevel'] as int? ??
          _asMap(vipData)?['redVipLevel'] as int?;
      vipLabel = switch (vipType) {
        10 => 'VIP${level != null ? ' Lv$level' : ''}',
        11 => '学生会员',
        20 || 40 => '黑胶SVIP${level != null ? ' Lv$level' : ''}',
        _ => null,
      };
    } catch (_) {
      // 会员信息获取失败不阻塞资料展示
    }
    return (nickname: nickname, vipLabel: vipLabel);
  }

  @override
  Future<SourceAccount?> refreshAccountInfo(SourceAccount account) async {
    final info = await fetchAccountSummary();
    if (info == null) return null;
    return account.copyWith(
      nickname: info.nickname,
      vipLabel: info.vipLabel,
    );
  }

  // ---------- 账号歌单能力（RemotePlaylistCapable） ----------

  @override
  Future<List<RemotePlaylist>> fetchRemotePlaylists(String userId) async {
    // uid 传空串 = 网易云按当前 Cookie 返回本人歌单，保持原行为
    final response = await _dio.get<dynamic>(
      '/api/user/playlist',
      queryParameters: <String, dynamic>{'uid': userId, 'limit': 100},
      options: Options(responseType: ResponseType.plain),
    );
    final list =
        _asMap(_decoded(response))?['playlist'] as List<dynamic>?;
    if (list == null) return const <RemotePlaylist>[];
    return list
        .map(_parseUserPlaylist)
        .whereType<RemotePlaylist>()
        .toList(growable: false);
  }

  RemotePlaylist? _parseUserPlaylist(dynamic raw) {
    final p = _asMap(raw);
    if (p == null) return null;
    final id = p['id'] as int?;
    final name = p['name'] as String?;
    if (id == null || name == null) return null;
    return RemotePlaylist(
      sourceId: sourceId,
      id: '$id',
      name: name,
      trackCount: p['trackCount'] as int? ?? 0,
      coverUrl: p['coverImgUrl'] as String?,
      playCount: p['playCount'] as int? ?? 0,
    );
  }

  /// 歌单详情 → 统一曲目列表（登录 Cookie 越权可见 VIP 曲目信息）。
  @override
  Future<List<Track>> fetchRemotePlaylistTracks(String playlistId) async {
    final id = int.tryParse(playlistId);
    if (id == null) return const <Track>[];
    final response = await _dio.get<dynamic>(
      '/api/playlist/detail',
      queryParameters: <String, dynamic>{'id': id},
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
      coverUrl: (album?['picUrl'] as String?)?.toHttps(),
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
    final credentials = await credentialReader();
    final musicU = credentials['MUSIC_U'];
    if (musicU == null || musicU.isEmpty) return false;
    // 网络异常由 _fetchProfile 抛 DioException 向上传递：
    // 上层据此保留乐观登录态，只有「确认无效」才返回 false。
    final profile = await _fetchProfile(cookie: 'MUSIC_U=$musicU');
    return profile != null &&
        ((profile['nickname'] as String?)?.isNotEmpty ?? false);
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

  /// 是否已有登录凭据（用于失败提示分级）。
  Future<bool> _hasCredentials() async {
    try {
      final credentials = await credentialReader();
      return (credentials['MUSIC_U'] ?? '').isNotEmpty;
    } catch (_) {
      return false;
    }
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
      coverUrl: (album?['picUrl'] as String?)?.toHttps(),
      sourceData: <String, dynamic>{'neteaseId': songId},
    );
  }

  Map<String, dynamic>? _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;
}
