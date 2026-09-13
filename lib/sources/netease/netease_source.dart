import 'dart:math';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import 'netease_crypto.dart';

import '../../core/logging/app_logger.dart';
import '../../core/error/source_exception.dart';
import '../../core/utils/url_utils.dart';
import '../../core/model/remote_playlist.dart';
import '../../core/model/track.dart';
import '../../core/network/response_decoder.dart';
import '../../core/network/source_auth_interceptor.dart';
import '../../core/network/source_dio.dart';
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
    this.bitrateProvider,
  });

  /// 渠道唯一标识与展示信息。
  static const String id = 'netease';

  /// 会话过期回调（由组合根接 AccountNotifier）。
  final void Function()? onSessionExpired;

  /// 音质档位（bitrate bps）：由组合根注入设置层映射，缺省 320k。
  final int Function()? bitrateProvider;

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

  late final Dio _dio = buildSourceDio(
    sourceId: NeteaseSource.id,
    baseUrl: 'https://music.163.com',
    readCredentials: credentialReader,
    onSessionExpired: onSessionExpired,
    headers: <String, String>{
      'Referer': 'https://music.163.com',
      'User-Agent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15',
    },
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
      final songs = asList(result?['songs']);
      if (songs == null) return const <Track>[];
      final tracks =
          songs.map(_trackFromSearchSong).whereType<Track>().toList();
      // 搜索接口的 result.songs[].album.picUrl 实测恒为 null（EMU/线上验证）：
      // 用 /api/song/detail 批量接口一次补全封面，失败静默不影响结果
      await _fillCoversFromDetail(tracks);
      return List.unmodifiable(tracks);
    } on DioException catch (e) {
      AppLog.debug(
        'search 失败: type=${e.type} '
        'status=${e.response?.statusCode} msg=${e.message}',
        tag: 'MusaicNetease',
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
      final songs = asList(_decoded(response)?['songs']);
      if (songs == null || songs.isEmpty) return track;
      final detail = _asMap(songs.first);
      if (detail == null) return track;
      final album = _asMap(detail['album']);
      final durationMs = asIntOrNull(detail['duration']);
      return track.copyWith(
        album: asStringOrNull(album?['name']) ?? track.album,
        coverUrl: asStringOrNull(album?['picUrl'])?.toHttps() ?? track.coverUrl,
        duration:
            durationMs == null
                ? track.duration
                : Duration(milliseconds: durationMs),
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
          'br': bitrateProvider?.call() ?? 320000,
          'csrf_token': '',
        },
        options: Options(responseType: ResponseType.plain),
      );
      final data = asList(_asMap(_decoded(response))?['data']);
      if (data == null || data.isEmpty) {
        throw UnavailableStreamException('该曲目暂不可播放', sourceId: sourceId);
      }
      final item = _asMap(data.first);
      final url = asStringOrNull(item?['url']);
      final code = asIntOrNull(item?['code']) ?? -1;
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
      final secureUrl =
          url.startsWith('http://')
              ? url.replaceFirst('http://', 'https://')
              : url;
      return ResolvedStream(
        url: secureUrl,
        headers: <String, String>{'Referer': 'https://music.163.com'},
      );
    } on DioException {
      throw NetworkSourceException('获取播放地址失败：网络异常', sourceId: sourceId);
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
    CredentialField(
      key: 'phone',
      label: '手机号',
      numeric: true,
      placeholder: '11 位手机号',
    ),
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
    final hex =
        List.generate(
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
      'osver': 'Microsoft-Windows-10-Professional-build-22631-64bit',
      'deviceId': hex,
      'os': 'pc',
      'channel': 'netease',
      'appver': '3.0.18.203152',
    }.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// weapi POST；[skipAuth] 避免过期 MUSIC_U 盖掉游客 Cookie。
  Future<Response<dynamic>> _weapiPost(
    String path,
    Map<String, dynamic> payload, {
    bool skipAuth = false,
    Map<String, String>? headers,
  }) async {
    final (:params, :encSecKey) = NeteaseCrypto.encryptPayload(payload);
    var options = Options(
      contentType: Headers.formUrlEncodedContentType,
      responseType: ResponseType.plain,
      headers: <String, String>{'Cookie': _guestCookie(), ...?headers},
    );
    if (skipAuth) {
      options = SourceAuthInterceptor.skipAuth(options);
    }
    return _dio.post<dynamic>(
      path,
      options: options,
      data:
          'params=${Uri.encodeQueryComponent(params)}'
          '&encSecKey=${Uri.encodeQueryComponent(encSecKey)}',
    );
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
    try {
      final response = await _weapiPost(
        '/weapi/w/login/cellphone',
        payload,
        skipAuth: true,
        headers: <String, String>{
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
              'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 '
              'Safari/537.36 Edg/124.0.0.0',
        },
      );
      final data = _asMap(_decoded(response));
      final code = asIntOrNull(data?['code']) ?? -1;
      if (code != 200) {
        final message =
            asStringOrNull(data?['message']) ??
            asStringOrNull(data?['msg']) ??
            '';
        return AuthFailure(
          reason: AuthFailureReason.invalidCredentials,
          message: message.isEmpty ? '手机号或密码错误（code $code）' : message,
        );
      }
      final musicU =
          _extractMusicU(response) ??
          _musicUFromBodyCookie(asStringOrNull(data?['cookie']));
      if (musicU == null || musicU.isEmpty) {
        return const AuthFailure(
          reason: AuthFailureReason.serverError,
          message: '登录成功但未返回凭据，请重试',
        );
      }
      final profile = _asMap(data?['profile']);
      final nickname = asStringOrNull(profile?['nickname']) ?? '';
      return AuthSuccess(
        SourceAccount.markNow(
          sourceId: sourceId,
          status: AccountStatus.loggedIn,
          userId: profile?['userId']?.toString(),
          nickname: nickname.isEmpty ? '网易云用户' : nickname,
          avatarUrl: asStringOrNull(profile?['avatarUrl']),
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
      response = await _weapiPost(
        '/weapi/login/qrcode/unikey',
        <String, dynamic>{'type': 1},
        skipAuth: true,
      );
    } on DioException catch (e) {
      AppLog.debug(
        'createQrLogin DioException: type=${e.type} '
        'status=${e.response?.statusCode} msg=${e.message} '
        'error=${e.error}',
        tag: 'MusaicNetease',
      );
      rethrow;
    }
    final data = _asMap(_decoded(response));
    // 只记录结构与状态，**不打印响应体**：该响应含登录 unikey。
    AppLog.debug(
      'createQrLogin status=${response.statusCode} '
      'bodyKeys=${data?.keys.toList()}',
      tag: 'MusaicNetease',
    );
    final key = asStringOrNull(data?['unikey']) ?? '';
    if (key.isEmpty) {
      throw NetworkSourceException('获取登录二维码失败', sourceId: sourceId);
    }
    return (key: key, qrContent: 'https://music.163.com/login?codekey=$key');
  }

  /// 轮询二维码状态。
  ///
  /// 803 授权成功：MUSIC_U 可能出现在 Set-Cookie 头或响应体 cookie 字段，
  /// 两路都取，避免只读 body 漏凭据导致「扫码后无动静」。
  Future<QrLoginPoll> pollQrLogin(String key) async {
    final response = await _weapiPost(
      '/weapi/login/qrcode/client/login',
      <String, dynamic>{'key': key, 'type': 1},
      skipAuth: true,
    );
    final data = _asMap(_decoded(response));
    final code = asIntOrNull(data?['code']) ?? -1;
    switch (code) {
      case 800:
        return QrLoginPoll.expired();
      case 802:
        return QrLoginPoll.scanned();
      case 803:
        final musicU =
            _extractMusicU(response) ??
            _musicUFromBodyCookie(asStringOrNull(data?['cookie']) ?? '');
        AppLog.info(
          '二维码授权成功：musicU='
          '${musicU == null ? '缺失' : '已取得(${musicU.length}字符)'}',
          tag: 'MusaicNetease',
        );
        if (musicU == null || musicU.isEmpty) {
          throw NetworkSourceException('授权成功但未取得登录凭据，请重试', sourceId: sourceId);
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
        AppLog.debug('二维码轮询 code=$code', tag: 'MusaicNetease');
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
    final nickname = asStringOrNull(profile?['nickname']);
    if (profile == null || nickname == null || nickname.isEmpty) {
      return null;
    }

    // 会员状态：weapi openvip v2（vipType 10=VIP 20/40=黑胶 11=学生）
    String? vipLabel;
    try {
      final vipResp = await _weapiPost(
        '/weapi/openvip/v2/info',
        <String, dynamic>{'csrf_token': ''},
        skipAuth: true,
        headers: <String, String>{'Cookie': cookieHeader},
      );
      final vipData = _asMap(_decoded(vipResp))?['data'];
      final redPlus = _asMap(vipData)?['redplus'];
      final vipType =
          asIntOrNull(_asMap(redPlus)?['vipType']) ??
          asIntOrNull(_asMap(vipData)?['vipType']) ??
          0;
      final level =
          asIntOrNull(_asMap(redPlus)?['redVipLevel']) ??
          asIntOrNull(_asMap(vipData)?['redVipLevel']);
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
    return account.copyWith(nickname: info.nickname, vipLabel: info.vipLabel);
  }

  // ---------- 账号歌单能力（RemotePlaylistCapable） ----------

  /// 账号歌单列表。
  ///
  /// 失败处理与搜索 / 播放地址对齐（此前这里是唯一没有 try/catch 的取数路径，
  /// 网络异常会以裸 [DioException] 逃到 UI 层）：
  /// - 网络不可达 / 超时 / 4xx-5xx → [NetworkSourceException]；
  /// - 未登录、凭据失效（HTTP 401 或业务码 301）→ [AuthRequiredException]；
  /// - **空歌单不是失败**：返回空列表，由调用方按「无歌单」渲染。
  @override
  Future<List<RemotePlaylist>> fetchRemotePlaylists(String userId) async {
    try {
      // uid 传空串 = 网易云按当前 Cookie 返回本人歌单，保持原行为
      final response = await _dio.get<dynamic>(
        '/api/user/playlist',
        queryParameters: <String, dynamic>{'uid': userId, 'limit': 100},
        options: Options(responseType: ResponseType.plain),
      );
      final body = _asMap(_decoded(response));
      _throwIfAuthRequired(body);
      return parseRemotePlaylists(body?['playlist']);
    } on DioException catch (e) {
      throw normalizeDioException(e, '获取账号歌单失败');
    }
  }

  /// 解析 `/api/user/playlist` 的 `playlist` 数组。
  ///
  /// 结构漂移（非数组 / 元素类型不符）降级为空列表而非抛异常——与 QQ 的
  /// [QqMusicSource.parseRemotePlaylists] 契约一致，消费方据此隐藏该分区。
  @visibleForTesting
  static List<RemotePlaylist> parseRemotePlaylists(Object? raw) {
    final list = asList(raw);
    if (list == null) return const <RemotePlaylist>[];
    return list
        .map(parseRemotePlaylist)
        .whereType<RemotePlaylist>()
        .toList(growable: false);
  }

  /// 单条歌单摘要 → 统一模型；缺 id 或名称为空的条目丢弃。
  ///
  /// 名称判空同 QQ：接口会夹带已删除歌单的占位项，渲染出来是一行点不动的
  /// 空白卡片，宁可少一项。
  @visibleForTesting
  static RemotePlaylist? parseRemotePlaylist(Object? raw) {
    final p = asMap(raw);
    if (p == null) return null;
    final id = asIntOrNull(p['id']);
    final name = asStringOrNull(p['name']);
    if (id == null || name == null || name.isEmpty) return null;
    return RemotePlaylist(
      sourceId: NeteaseSource.id,
      id: '$id',
      name: name,
      trackCount: asIntOrNull(p['trackCount']) ?? 0,
      coverUrl: asStringOrNull(p['coverImgUrl'])?.toHttps(),
      playCount: asIntOrNull(p['playCount']) ?? 0,
    );
  }

  /// 歌单详情 → 统一曲目列表（登录 Cookie 越权可见 VIP 曲目信息）。
  ///
  /// 失败处理同上；非数字 id 不可能命中网易云歌单，直接空态而不发错请求。
  @override
  Future<List<Track>> fetchRemotePlaylistTracks(String playlistId) async {
    final id = int.tryParse(playlistId);
    if (id == null) return const <Track>[];
    try {
      final response = await _dio.get<dynamic>(
        '/api/playlist/detail',
        queryParameters: <String, dynamic>{'id': id},
        options: Options(responseType: ResponseType.plain),
      );
      final body = _asMap(_decoded(response));
      _throwIfAuthRequired(body);
      return parseRemotePlaylistTracks(_asMap(body?['result'])?['tracks']);
    } on DioException catch (e) {
      throw normalizeDioException(e, '获取歌单曲目失败');
    }
  }

  /// 解析 `/api/playlist/detail` 的 `result.tracks` 数组；非数组降级为空列表。
  @visibleForTesting
  static List<Track> parseRemotePlaylistTracks(Object? raw) {
    final tracks = asList(raw);
    if (tracks == null) return const <Track>[];
    return tracks
        .map(parseDetailSong)
        .whereType<Track>()
        .toList(growable: false);
  }

  /// 歌单详情曲目 → [Track]；缺 id 或标题的条目丢弃。
  ///
  /// 标题判空同 QQ 的 [QqMusicSource.parseDissSong]：名称为空的条目渲染出来是
  /// 一行认不出、也搜不到的空条目，宁可少一行。
  @visibleForTesting
  static Track? parseDetailSong(Object? raw) {
    final song = asMap(raw);
    if (song == null) return null;
    final songId = asIntOrNull(song['id']);
    final name = asStringOrNull(song['name']);
    if (songId == null || name == null || name.isEmpty) return null;
    final artists = (asList(song['artists']) ?? const <dynamic>[])
        .map((a) => asStringOrNull(asMap(a)?['name']))
        .whereType<String>()
        .join('/');
    final album = asMap(song['album']);
    final durationMs = asIntOrNull(song['duration']);
    return Track(
      id: '$songId',
      sourceId: NeteaseSource.id,
      title: name,
      artist: artists.isEmpty ? '未知歌手' : artists,
      album: asStringOrNull(album?['name']),
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      coverUrl: asStringOrNull(album?['picUrl'])?.toHttps(),
      sourceData: <String, dynamic>{'neteaseId': songId},
    );
  }

  /// 未登录 / 凭据失效：网易云以业务码 301 表达。
  ///
  /// 必须显式抛出：否则「需要登录」会被调用方误读成「这个账号没有歌单」，
  /// 用户看到的是空态而不是「去登录」（与 B6 同一类静默吞错问题）。
  void _throwIfAuthRequired(Map<String, dynamic>? body) {
    if (asIntOrNull(body?['code']) == 301) {
      throw AuthRequiredException('登录已过期，请重新登录网易云', sourceId: sourceId);
    }
  }

  /// [DioException] → 渠道统一异常（与搜索 / 播放地址同一处理方式）。
  ///
  /// `@visibleForTesting` + static：失败映射是本能力唯一无法靠解析器覆盖的
  /// 分支（需要真实 Dio），暴露出来才能用构造出的 [DioException] 直接断言。
  @visibleForTesting
  static SourceException normalizeDioException(DioException e, String action) {
    AppLog.debug(
      '$action: type=${e.type} status=${e.response?.statusCode} msg=${e.message}',
      tag: 'MusaicNetease',
    );
    if (e.response?.statusCode == 401) {
      return AuthRequiredException('登录已过期，请重新登录网易云', sourceId: id);
    }
    return NetworkSourceException('$action：网络异常', sourceId: id);
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
      final nickname = asStringOrNull(profile?['nickname']);
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
          avatarUrl: asStringOrNull(profile['avatarUrl']),
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
        ((asStringOrNull(profile['nickname'])?.isNotEmpty) ?? false);
  }

  // ---------- 工具 ----------

  /// 统一解码响应体：老接口返回的 Content-Type 常不是 application/json，
  /// Dio 会把 JSON 正文留成 String，这里手动解码兜底。
  dynamic _decoded(Response<dynamic> response) =>
      decodeResponseBody(response.data);

  String? _lyricText(Map<String, dynamic> data, String key) {
    final value = asStringOrNull(_asMap(data[key])?['lyric']);
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  Future<Map<String, dynamic>?> _fetchProfile({required String cookie}) async {
    final response = await _dio.get<dynamic>(
      '/api/nuser/account/get',
      options: SourceAuthInterceptor.skipAuth(
        Options(
          headers: <String, String>{'Cookie': cookie},
          responseType: ResponseType.plain,
        ),
      ),
    );
    final data = _asMap(_decoded(response));
    if (data == null || (asIntOrNull(data['code']) ?? -1) != 200) return null;
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
      asIntOrNull(track.sourceData?['neteaseId']) ?? int.tryParse(track.id);

  /// 用 /api/song/detail 批量补全搜索结果的封面与专辑名（一次请求）。
  ///
  /// 搜索接口（/api/search/get/web）返回的 album.picUrl 实测恒为 null；
  /// 详情接口带完整 picUrl。任一失败静默返回，不影响搜索结果本身。
  Future<void> _fillCoversFromDetail(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final ids = tracks
        .map((t) => int.tryParse(t.id))
        .whereType<int>()
        .toList(growable: false);
    if (ids.isEmpty) return;
    try {
      final response = await _dio.get<dynamic>(
        '/api/song/detail',
        queryParameters: <String, dynamic>{'ids': '[${ids.join(',')}]'},
        options: Options(responseType: ResponseType.plain),
      );
      final songs = asList(_decoded(response)?['songs']);
      if (songs == null) return;
      final picById = <int, String>{};
      final albumById = <int, String>{};
      for (final raw in songs) {
        final song = _asMap(raw);
        final id = asIntOrNull(song?['id']);
        final album = _asMap(song?['album']);
        final pic = asStringOrNull(album?['picUrl'])?.toHttps();
        if (song == null || id == null || pic == null) continue;
        picById[id] = pic;
        final albumName = asStringOrNull(album?['name']);
        if (albumName != null) albumById[id] = albumName;
      }
      if (picById.isEmpty) return;
      for (var i = 0; i < tracks.length; i++) {
        final id = int.tryParse(tracks[i].id);
        final pic = id == null ? null : picById[id];
        if (pic == null) continue;
        tracks[i] = tracks[i].copyWith(
          coverUrl: pic,
          album: tracks[i].album ?? (id == null ? null : albumById[id]),
        );
      }
    } catch (_) {
      // 封面补全失败不影响搜索结果
    }
  }

  Track? _trackFromSearchSong(dynamic raw) {
    final song = _asMap(raw);
    if (song == null) return null;
    final songId = asIntOrNull(song['id']);
    final name = asStringOrNull(song['name']);
    if (songId == null || name == null) return null;
    final artists = (asList(song['artists']) ?? const <dynamic>[])
        .map((a) => asStringOrNull(_asMap(a)?['name']))
        .whereType<String>()
        .join('/');
    final album = _asMap(song['album']);
    final durationMs = asIntOrNull(song['duration']);
    return Track(
      id: '$songId',
      sourceId: NeteaseSource.id,
      title: name,
      artist: artists.isEmpty ? '未知歌手' : artists,
      album: asStringOrNull(album?['name']),
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      coverUrl: asStringOrNull(album?['picUrl'])?.toHttps(),
      sourceData: <String, dynamic>{'neteaseId': songId},
    );
  }

  Map<String, dynamic>? _asMap(dynamic value) => asMap(value);
}
