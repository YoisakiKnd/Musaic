import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import '../../core/logging/app_logger.dart';
import '../../core/error/source_exception.dart';
import '../../core/model/remote_playlist.dart';
import '../../core/model/track.dart';
import '../../core/network/response_decoder.dart';
import '../../core/network/source_dio.dart';
import '../../core/source/capabilities.dart';
import '../../core/source/music_source.dart';
import '../../core/auth/auth_capability.dart';
import '../../core/auth/auth_result.dart';
import '../../core/auth/qr_login_poll.dart';
import '../../core/auth/source_account.dart';
import '../../core/utils/url_utils.dart';
import '../../core/lyrics/lrc_parser.dart';
import '../../core/lyrics/lyric_bundle.dart';

/// 酷狗音乐渠道。
///
/// 匿名能力：搜索 / 播放直链 / LRC 歌词；
/// 登录能力：h5 二维码扫码（[QrLoginCapable]，web 签名 MD5 双盐），
/// 成功后凭据为 token/userid，注入 Cookie 解锁完整试听。
/// 歌单能力：[RemotePlaylistCapable]（Android 签名，公开发现链）。
class KugouSource extends MusicSource
    implements QrLoginCapable, RemotePlaylistCapable {
  KugouSource({required super.credentialReader, this.onSessionExpired});

  static const String id = 'kugou';

  /// 会话过期回调（由组合根接 AccountNotifier）。
  final void Function()? onSessionExpired;

  @override
  String get sourceId => KugouSource.id;

  @override
  String get displayName => '酷狗音乐';

  @override
  AuthCapability get authCapability => AuthCapability.qr;

  final Random _random = Random.secure();

  /// 设备 MID（32 位 hex，实例生命周期内稳定，参与签名）。
  late final String _mid =
      List.generate(32, (_) => '0123456789abcdef'[_random.nextInt(16)]).join();

  static const String _salt = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';

  // ---------- 账号歌单（RemotePlaylistCapable）常量 ----------
  //
  // 以下端点与签名规则来自 MIT 许可的参考实现
  // MakcRe/KuGouMusicApi（Copyright 2023 MakcRe，MIT License）：
  //   module/top_playlist.js            → POST /v2/special_recommend
  //   module/playlist_track_all.js      → GET  /pubsongs/v2/get_other_list_file_nofilt
  //   module/playlist_detail.js         → POST /v3/get_list_info
  //   util/helper.js                    → signatureAndroidParams / signParamsKey
  // 仅参照其接口形态与签名算法，未复制其代码。

  /// Android 版签名盐（与 web 盐不同）。
  ///
  /// 注意：歌单接口用 Android 签名，**不能**复用本类已有的 [_salt]（web 盐）。
  static const String _androidSalt = 'OIlwieks28dk2k092lksi2UIkp';

  /// Android 版固定参数（参考实现 util/config.json）。
  static const String _androidAppId = '1005';
  static const String _androidClientVer = '20489';

  static const String _androidUserAgent =
      'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';

  static const String _gatewayBase = 'https://gateway.kugou.com';

  /// 公开歌单发现（歌单推荐）。
  static const String _discoveryRouter = 'specialrec.service.kugou.com';

  /// 歌单曲目列表。
  static const String _trackListPath =
      '/pubsongs/v2/get_other_list_file_nofilt';

  /// 歌单详情（批量取曲目数）。
  static const String _listInfoPath = '/v3/get_list_info';
  static const String _listInfoRouter = 'pubsongs.kugou.com';

  /// [fetchRemotePlaylistTracks] 单次请求的曲目数上限。
  ///
  /// 实测该端点接受 pagesize 300/1000 且无截断（2026-09-13），
  /// 但歌单可以有几万首，因此仍按页拉取，避免一次响应过大。
  static const int _trackPageSize = 300;

  /// 曲目分页的硬上限（安全阀，防止上游 count 异常导致无限循环）。
  static const int _trackPageLimit = 100;

  /// [fetchRemotePlaylists] 返回的歌单条数上限。
  static const int _discoveryPageSize = 30;

  /// [_fetchTrackCounts] 单次批量请求的 id 数上限。
  ///
  /// **实测上限为 10**：1/2/3/5/10 个 id 均正常返回，
  /// 15 个 id 直接返回 status 0 / error_code 20010（2026-09-13）。
  static const int _countBatchSize = 10;

  late final Dio _dio = buildSourceDio(
    sourceId: KugouSource.id,
    readCredentials: credentialReader,
    onSessionExpired: onSessionExpired,
    headers: <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
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
      final lists = asList(
        _asMap(_asMap(_decoded(response))?['data'])?['lists'],
      );
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
    final hash = asStringOrNull(track.sourceData?['hash']);
    if (hash == null || hash.isEmpty) {
      throw UnavailableStreamException('曲目缺少渠道标识', sourceId: sourceId);
    }
    try {
      String token = '';
      String userid = '';
      try {
        final credentials = await credentialReader();
        token = credentials['token'] ?? '';
        userid = credentials['userid'] ?? '';
      } catch (_) {}
      // 凭据走 Cookie 头而非 URL query（避免进入代理 / 服务端日志）。
      final response = await _dio.get<dynamic>(
        'https://m.kugou.com/app/i/getSongInfo.php',
        queryParameters: <String, dynamic>{'cmd': 'playInfo', 'hash': hash},
        options: Options(
          headers: <String, String>{
            if (token.isNotEmpty || userid.isNotEmpty)
              'Cookie': 'token=$token; userid=$userid',
          },
        ),
      );
      final data = _asMap(_decoded(response));
      final status = asIntOrNull(data?['status']) ?? -1;
      final url = asStringOrNull(data?['url']);
      if (status != 1 || url == null || url.isEmpty) {
        // 分级提示：未登录引导登录；已登录则说明版权限制
        final loggedIn = await _hasCredentials();
        throw UnavailableStreamException(
          loggedIn ? '受版权方限制，该曲目暂不可播放' : '该曲目需要版权授权，请先在「设置 → 账号管理」登录酷狗后尝试播放',
          sourceId: sourceId,
        );
      }
      return ResolvedStream(url: url, isLocalFile: false);
    } on DioException {
      throw NetworkSourceException('获取播放地址失败：网络异常', sourceId: sourceId);
    }
  }

  @override
  Future<LyricBundle?> fetchLyrics(Track track) async {
    final hash = asStringOrNull(track.sourceData?['hash']);
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
      final candidates = asList(_asMap(_decoded(search))?['candidates']);
      if (candidates == null || candidates.isEmpty) return null;
      final first = _asMap(candidates.first);
      final lyricId = asStringOrNull(first?['id']);
      final accessKey = asStringOrNull(first?['accesskey']);
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
      final content = asStringOrNull(_asMap(_decoded(download))?['content']);
      if (content == null || content.trim().isEmpty) return null;
      var lrcText = content;
      if (!content.trimLeft().startsWith('[')) {
        try {
          lrcText = utf8.decode(base64.decode(content.trim()));
        } catch (_) {}
      }
      final bundle = LrcParser.parse(lrcText);
      return bundle.isEmpty ? null : bundle;
    } catch (_) {
      return null;
    }
  }

  // ---------- 真实登录（h5 二维码扫码） ----------

  @override
  List<QrLoginFlow> get qrLoginFlows => [
    QrLoginFlow(
      id: 'qr',
      label: '扫码登录',
      scanHint: '请使用酷狗音乐 App 扫码',
      create: () async {
        final session = await createQrLogin();
        return QrLoginSession(
          pollKey: session.qrKey,
          png: session.png,
          contentUrl: session.qrContent,
        );
      },
      poll: (session) => pollQrLogin(session.pollKey),
      userIdCredentialKey: 'userid',
      fallbackNickname: '酷狗用户',
      footerHint: '扫码登录后可同步会员权益与账号歌单',
    ),
  ];

  /// 创建二维码登录会话：返回扫码内容与二维码 PNG。
  Future<({String qrKey, Uint8List png, String qrContent})>
  createQrLogin() async {
    final data = await _signedGet(
      'https://login-user.kugou.com/v2/qrcode',
      <String, String>{
        'dfid': '-',
        'mid': _mid,
        'uuid': '-',
        'appid': '1014',
        'clientver': '20489',
        'clienttime': _nowSec(),
        'type': '1',
        'plat': '4',
        'qrcode_txt':
            'https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=1014&',
        'srcappid': '2919',
      },
    );
    final payload = _asMap(data)?['data'];
    final qrKey = asStringOrNull(_asMap(payload)?['qrcode']);
    final imgDataUrl = asStringOrNull(_asMap(payload)?['qrcode_img']);
    if (qrKey == null || qrKey.isEmpty) {
      throw NetworkSourceException('获取登录二维码失败', sourceId: sourceId);
    }
    Uint8List png;
    if (imgDataUrl != null && imgDataUrl.startsWith('data:image')) {
      final b64 = imgDataUrl.split(',').last;
      png = base64.decode(b64);
    } else {
      throw NetworkSourceException('二维码图像缺失', sourceId: sourceId);
    }
    return (
      qrKey: qrKey,
      png: png,
      qrContent:
          'https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=$qrKey',
    );
  }

  /// 轮询二维码状态：0 过期 / 1 等待 / 2 已扫待确认 / 4 成功（含 token）。
  Future<QrLoginPoll> pollQrLogin(String qrKey) async {
    final data = await _signedGet(
      'https://login-user.kugou.com/v2/get_userinfo_qrcode',
      <String, String>{
        'dfid': '-',
        'mid': _mid,
        'uuid': '-',
        'appid': '1014',
        'clientver': '20489',
        'clienttime': _nowSec(),
        'plat': '4',
        'srcappid': '2919',
        'qrcode': qrKey,
      },
    );
    final payload = _asMap(data)?['data'];
    final status = asIntOrNull(_asMap(payload)?['status']) ?? -1;
    switch (status) {
      case 0:
        return const QrLoginPollExpired();
      case 1:
        return const QrLoginPollWaiting();
      case 2:
        return const QrLoginPollScanned();
      case 4:
        final token = asStringOrNull(_asMap(payload)?['token']);
        final userid = _asMap(payload)?['userid'];
        if (token == null || token.isEmpty || userid == null) {
          throw NetworkSourceException('登录凭据缺失，请重试', sourceId: sourceId);
        }
        return QrLoginPoll.success(
          credentials: <String, String>{'token': token, 'userid': '$userid'},
          nickname: asStringOrNull(_asMap(payload)?['nickname']),
        );
      default:
        AppLog.debug('未知二维码状态 $status', tag: 'MusaicKugou');
        return const QrLoginPollWaiting();
    }
  }

  @override
  Future<AuthResult> login(Map<String, String> credentials) async {
    final token = credentials['token']?.trim() ?? '';
    final userid = credentials['userid']?.trim() ?? '';
    if (token.isEmpty || userid.isEmpty) {
      return const AuthFailure(
        reason: AuthFailureReason.invalidCredentials,
        message: '请填写完整凭据（token 与 userid）',
      );
    }
    final nickname = await _fetchNickname(token: token, userid: userid);
    if (nickname == null) {
      return const AuthFailure(
        reason: AuthFailureReason.invalidCredentials,
        message: '凭据无效或已过期，请重新登录',
      );
    }
    return AuthSuccess(
      SourceAccount.markNow(
        sourceId: sourceId,
        status: AccountStatus.loggedIn,
        userId: userid,
        nickname: nickname,
      ),
      credentials: <String, String>{'token': token, 'userid': userid},
    );
  }

  @override
  Future<bool> checkSession() async {
    final credentials = await credentialReader();
    final token = credentials['token'];
    final userid = credentials['userid'];
    if (token == null || token.isEmpty || userid == null) return false;
    // throwOnError：网络异常向上抛，AccountNotifier 保留乐观登录态，
    // 只有「确认凭据无效」才返回 false。
    final nickname = await _fetchNickname(
      token: token,
      userid: userid,
      throwOnError: true,
    );
    return nickname != null;
  }

  Future<String?> _fetchNickname({
    required String token,
    required String userid,
    bool throwOnError = false,
  }) async {
    final Response<dynamic> response;
    try {
      // 凭据改走 Cookie 头而非 URL query：query 会进入代理 / CDN /
      // 服务端访问日志，token 与 userid 属于会话凭据（P1 安全回归）。
      response = await _dio.get<dynamic>(
        'https://userservice.kugou.com/rpc/v1/get_user_info',
        options: Options(
          responseType: ResponseType.plain,
          headers: <String, String>{'Cookie': 'token=$token; userid=$userid'},
        ),
      );
    } catch (_) {
      if (throwOnError) rethrow;
      return null;
    }
    final data = _asMap(_decoded(response));
    final userInfo = _asMap(_asMap(_asMap(data)?['data'])?['userInfo']);
    final nick =
        asStringOrNull(userInfo?['nickname']) ??
        asStringOrNull(userInfo?['username']);
    return (nick == null || nick.isEmpty) ? null : nick;
  }

  /// 是否已有登录凭据（用于失败提示分级）。
  Future<bool> _hasCredentials() async {
    try {
      final credentials = await credentialReader();
      return (credentials['token'] ?? '').isNotEmpty &&
          (credentials['userid'] ?? '').isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<SourceAccount?> refreshAccountInfo(SourceAccount account) async {
    final credentials = await credentialReader();
    final token = credentials['token'] ?? '';
    final userid = credentials['userid'] ?? '';
    if (token.isEmpty || userid.isEmpty) return null;
    final nickname = await _fetchNickname(token: token, userid: userid);
    if (nickname == null) return null;
    return account.copyWith(nickname: nickname);
  }

  // ---------- 账号歌单能力（RemotePlaylistCapable） ----------
  //
  // 与网易云 / QQ 不同，酷狗的**公开歌单链无需登录**（实测 2026-09-13）：
  //   发现  POST /v2/special_recommend                  → 歌单推荐列表
  //   计数  POST /v3/get_list_info                      → 批量取曲目数（≤10 id/次）
  //   曲目  GET  /pubsongs/v2/get_other_list_file_nofilt → 曲目分页
  // 三个端点都走 **Android 签名**（与类内已有的 web 签名不是同一套盐）。

  @override
  Future<List<RemotePlaylist>> fetchRemotePlaylists(String userId) async {
    try {
      final clientTime = _nowSec();
      final body = jsonEncode(<String, dynamic>{
        'appid': int.parse(_androidAppId),
        'mid': _mid,
        'clientver': int.parse(_androidClientVer),
        'platform': 'android',
        'clienttime': int.parse(clientTime),
        'userid': 0,
        'module_id': 1,
        'page': 1,
        'pagesize': _discoveryPageSize,
        'key': androidParamsKey(clientTime),
        'special_recommend': <String, dynamic>{
          'withtag': 1,
          'withsong': 1,
          'sort': 1,
          'ugc': 1,
          'is_selected': 0,
          'withrecommend': 1,
          'area_code': 1,
          'categoryid': 0,
        },
        'req_multi': 1,
        'retrun_min': 5,
        'return_special_falg': 1,
      });
      final response = await _androidPost(
        path: '/v2/special_recommend',
        router: _discoveryRouter,
        body: body,
        clientTime: clientTime,
      );
      final decoded = _decoded(response);
      throwIfFailed(decoded, '获取账号歌单失败');
      final data = _asMap(_asMap(decoded)?['data']);
      final playlists = parseRemotePlaylists(data?['special_list']);
      if (playlists.isEmpty) return const <RemotePlaylist>[];

      // 发现接口**不返回曲目数**（percount 恒为 0，collectcount 是收藏人数），
      // 而 RemotePlaylist.trackCount 是必填并会渲染成「N 首」，
      // 因此必须再批量取一次真实曲目数。
      final counts = await _fetchTrackCounts(
        playlists.map((p) => p.id).toList(growable: false),
      );
      return <RemotePlaylist>[
        for (final playlist in playlists)
          if (counts[playlist.id] case final count?)
            RemotePlaylist(
              sourceId: playlist.sourceId,
              id: playlist.id,
              name: playlist.name,
              trackCount: count,
              playCount: playlist.playCount,
              coverUrl: playlist.coverUrl,
            )
          else
            playlist,
      ];
    } on DioException catch (e) {
      throw normalizeDioException(e, '获取账号歌单失败');
    }
  }

  @override
  Future<List<Track>> fetchRemotePlaylistTracks(String playlistId) async {
    final id = playlistId.trim();
    if (id.isEmpty) return const <Track>[];
    final tracks = <Track>[];
    try {
      var seen = 0;
      for (var page = 0; page < _trackPageLimit; page++) {
        final clientTime = _nowSec();
        final response = await _androidGet(
          path: _trackListPath,
          clientTime: clientTime,
          extraParams: <String, dynamic>{
            'area_code': 1,
            'begin_idx': page * _trackPageSize,
            'plat': 1,
            'type': 1,
            'mode': 1,
            'personal_switch': 1,
            'extend_fields': 'abtags,hot_cmt,popularization',
            'pagesize': _trackPageSize,
            'global_collection_id': id,
          },
        );
        final decoded = _decoded(response);
        throwIfFailed(decoded, '获取歌单曲目失败');
        final data = _asMap(_asMap(decoded)?['data']);
        final songs = asList(data?['songs']);
        // 空页 = 歌单已取完 / begin_idx 越界（实测越界返回空列表而非报错）
        if (songs == null || songs.isEmpty) break;
        tracks.addAll(songs.map(parseKugouSong).whereType<Track>());
        seen += songs.length;
        // count 是歌单总曲目数：已取满即停，少打一次空请求
        final total = asIntOrNull(data?['count']);
        if (total != null && seen >= total) break;
        // 不满一页说明已是最后一页
        if (songs.length < _trackPageSize) break;
      }
      return List<Track>.unmodifiable(tracks);
    } on DioException catch (e) {
      throw normalizeDioException(e, '获取歌单曲目失败');
    }
  }

  /// 批量取歌单曲目数（发现接口不提供）。
  ///
  /// 上游单次最多接受 [_countBatchSize] 个 id（实测 15 个即报 error_code 20010），
  /// 因此分片请求。**单片失败只影响该片的曲目数**：曲目数仅用于列表卡片展示，
  /// 让整份歌单列表跟着失败得不偿失；失败会记入诊断日志，不是静默吞掉。
  Future<Map<String, int>> _fetchTrackCounts(List<String> ids) async {
    final counts = <String, int>{};
    for (var start = 0; start < ids.length; start += _countBatchSize) {
      final end =
          (start + _countBatchSize) > ids.length
              ? ids.length
              : start + _countBatchSize;
      final chunk = ids.sublist(start, end);
      try {
        final clientTime = _nowSec();
        final body = jsonEncode(<String, dynamic>{
          'data': <Map<String, String>>[
            for (final id in chunk)
              <String, String>{'global_collection_id': id},
          ],
          'userid': 0,
          'token': '',
        });
        final response = await _androidPost(
          path: _listInfoPath,
          router: _listInfoRouter,
          body: body,
          clientTime: clientTime,
        );
        final decoded = _decoded(response);
        throwIfFailed(decoded, '获取歌单曲目数失败');
        for (final item
            in asList(_asMap(decoded)?['data']) ?? const <dynamic>[]) {
          final map = _asMap(item);
          final id = asStringOrNull(map?['global_collection_id']);
          final count = asIntOrNull(map?['count']);
          if (id != null && id.isNotEmpty && count != null) {
            counts[id] = count;
          }
        }
      } catch (e) {
        AppLog.warning('获取歌单曲目数失败（$start-$end）：$e', tag: 'MusaicKugou');
      }
    }
    return counts;
  }

  /// Android 签名 POST（歌单链）。
  Future<Response<dynamic>> _androidPost({
    required String path,
    required String body,
    required String clientTime,
    String? router,
  }) {
    final params = _androidParams(clientTime);
    return _dio.post<dynamic>(
      '$_gatewayBase$path',
      data: body,
      queryParameters: <String, dynamic>{
        ...params,
        'signature': androidSignature(params, body),
      },
      options: Options(
        contentType: Headers.jsonContentType,
        headers: <String, String>{
          ..._androidHeaders(clientTime),
          if (router != null) 'x-router': router,
        },
      ),
    );
  }

  /// Android 签名 GET（歌单曲目链）。
  Future<Response<dynamic>> _androidGet({
    required String path,
    required Map<String, dynamic> extraParams,
    required String clientTime,
  }) {
    final params = <String, dynamic>{
      ..._androidParams(clientTime),
      ...extraParams,
    };
    return _dio.get<dynamic>(
      '$_gatewayBase$path',
      queryParameters: <String, dynamic>{
        ...params,
        'signature': androidSignature(params, ''),
      },
      options: Options(headers: _androidHeaders(clientTime)),
    );
  }

  /// Android 请求的公共参数（参考实现 util/request.js 自动注入的那几个）。
  Map<String, dynamic> _androidParams(String clientTime) => <String, dynamic>{
    'dfid': '-',
    'mid': _mid,
    'uuid': '-',
    'appid': _androidAppId,
    'clientver': _androidClientVer,
    'clienttime': clientTime,
  };

  Map<String, String> _androidHeaders(String clientTime) => <String, String>{
    'User-Agent': _androidUserAgent,
    'dfid': '-',
    'clienttime': clientTime,
    'mid': _mid,
  };

  /// Android 签名：`MD5(salt + 排序后 k=v 拼接 + body + salt)`。
  ///
  /// 参数值里的对象 / 数组用**紧凑** JSON（无空格）参与拼接，对齐参考实现的
  /// `JSON.stringify` 语义。`body` 必须是**与实际发送字节完全一致**的字符串
  /// ——实测只要签名用的是同一份字符串，带不带空格都能通过；签名不符时
  /// 网关返回 error_code 200101。
  @visibleForTesting
  static String androidSignature(Map<String, dynamic> params, String body) {
    final keys = params.keys.toList()..sort();
    final buffer = StringBuffer();
    for (final key in keys) {
      final value = params[key];
      buffer.write('$key=');
      buffer.write(
        (value is Map || value is List) ? jsonEncode(value) : '$value',
      );
    }
    final raw = '$_androidSalt$buffer$body$_androidSalt';
    return crypto.md5.convert(utf8.encode(raw)).toString();
  }

  /// 发现接口的 `key` 参数：`MD5(appid + salt + clientver + data)`。
  ///
  /// 缺少它时该端点返回 HTTP 500（实测），是它而非签名导致早期探测失败。
  @visibleForTesting
  static String androidParamsKey(String data) {
    final raw = '$_androidAppId$_androidSalt$_androidClientVer$data';
    return crypto.md5.convert(utf8.encode(raw)).toString();
  }

  /// 业务层失败判定（对齐参考实现 util/request.js 的判据）。
  ///
  /// `status == 0` 或 `error_code != 0` 即失败。注意 error_code **20010 是
  /// 通用错误**（缺参、批量过大、未登录都会用它），不能据此判定为「未登录」。
  /// 无效歌单 id 则返回 `status 1 / error_code 0 / data {}`——属于**空结果**，
  /// 不是失败（与「空 ≠ 失败」的既有约定一致）。
  @visibleForTesting
  static void throwIfFailed(Object? decoded, String action) {
    final map = asMap(decoded);
    if (map == null) return;
    final status = asIntOrNull(map['status']);
    final errorCode = asIntOrNull(map['error_code']);
    final failed = status == 0 || (errorCode != null && errorCode != 0);
    if (!failed) return;
    AppLog.debug(
      '$action: status=$status error_code=$errorCode',
      tag: 'MusaicKugou',
    );
    throw NetworkSourceException(
      errorCode == null ? '$action：请求被拒绝' : '$action（错误码 $errorCode）',
      sourceId: KugouSource.id,
    );
  }

  /// [DioException] → 领域异常（与网易云 `normalizeDioException` 同形）。
  ///
  /// 独立成静态方法的原因：该分支依赖真实 Dio，是解析函数覆盖不到的一支，
  /// 静态化后测试可直接构造 [DioException] 断言映射结果。
  @visibleForTesting
  static SourceException normalizeDioException(DioException e, String action) {
    AppLog.debug(
      '$action: type=${e.type} status=${e.response?.statusCode} msg=${e.message}',
      tag: 'MusaicKugou',
    );
    if (e.response?.statusCode == 401) {
      return AuthRequiredException('登录已过期，请重新登录酷狗', sourceId: KugouSource.id);
    }
    return NetworkSourceException('$action：网络异常', sourceId: KugouSource.id);
  }

  /// 解析歌单列表（`data.special_list`）。
  ///
  /// 结构漂移 / 空数据一律退化为空列表（与网易云、QQ 一致，不抛异常）；
  /// 缺 id 或名称的条目直接丢弃——渲染出来是一张点不动的空白卡片。
  @visibleForTesting
  static List<RemotePlaylist> parseRemotePlaylists(Object? raw) {
    final list = asList(raw);
    if (list == null) return const <RemotePlaylist>[];
    final result = <RemotePlaylist>[];
    for (final item in list) {
      final playlist = parseRemotePlaylist(item);
      if (playlist != null) result.add(playlist);
    }
    return result;
  }

  @visibleForTesting
  static RemotePlaylist? parseRemotePlaylist(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    final id = asStringOrNull(map['global_collection_id']);
    final name = (asStringOrNull(map['specialname']) ?? '').trim();
    if (id == null || id.isEmpty || name.isEmpty) return null;
    final cover =
        asStringOrNull(map['imgurl']) ?? asStringOrNull(map['flexible_cover']);
    return RemotePlaylist(
      sourceId: KugouSource.id,
      id: id,
      name: name,
      // 发现接口不提供曲目数（percount 恒 0，collectcount 是收藏人数），
      // 真实曲目数由 [_fetchTrackCounts] 补齐，取不到时为 0。
      trackCount: 0,
      playCount: asIntOrNull(map['play_count']),
      coverUrl:
          (cover == null || cover.isEmpty)
              ? null
              : cover.replaceAll('{size}', '240').toHttps(),
    );
  }

  /// 解析歌单曲目条目（`data.songs[]`）。
  ///
  /// 实测 `songs[]` 会出现**只有 `fileid`/`shield` 的占位项**（无 name/hash），
  /// 这类条目点开无法播放，直接丢弃（与网易云丢弃空标题同处理）。
  ///
  /// `name` 形如「歌手 - 标题」，但标题本身可能含「-」，因此仅在
  /// 前缀与 `singerinfo` 一致时才剥离，避免误切标题。
  @visibleForTesting
  static Track? parseKugouSong(Object? raw) {
    final song = asMap(raw);
    if (song == null) return null;
    final hash = asStringOrNull(song['hash']);
    if (hash == null || hash.isEmpty) return null;
    final full = (asStringOrNull(song['name']) ?? '').trim();
    if (full.isEmpty) return null;

    final singers = <String>[];
    for (final item in asList(song['singerinfo']) ?? const <dynamic>[]) {
      final name = asStringOrNull(asMap(item)?['name']);
      if (name != null && name.isNotEmpty) singers.add(name);
    }
    var artist = singers.join('/');
    var title = full;
    final separator = full.indexOf(' - ');
    if (separator > 0) {
      final head = full.substring(0, separator).trim();
      if (artist.isEmpty || head == artist) {
        title = full.substring(separator + 3).trim();
        if (artist.isEmpty) artist = head;
      }
    }
    if (title.isEmpty) return null;
    if (artist.isEmpty) artist = '未知歌手';

    final album =
        (asStringOrNull(asMap(song['albuminfo'])?['name']) ?? '').trim();
    final cover = asStringOrNull(song['cover']);
    final millis = asIntOrNull(song['timelen']);
    return Track(
      id: hash,
      sourceId: KugouSource.id,
      title: title,
      artist: artist,
      album: album.isEmpty ? null : album,
      // 酷狗曲目时长是**毫秒**（勿照抄 QQ 的秒）
      duration:
          (millis == null || millis <= 0)
              ? null
              : Duration(milliseconds: millis),
      coverUrl:
          (cover == null || cover.isEmpty)
              ? null
              : cover.replaceAll('{size}', '240').toHttps(),
      sourceData: <String, dynamic>{
        'hash': hash,
        if (asStringOrNull(song['album_id']) case final albumId?)
          'albumId': albumId,
      },
    );
  }

  // ---------- 工具 ----------

  String _nowSec() =>
      (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();

  /// web 签名：MD5(salt + 排序后 k=v 拼接 + salt)。
  String _webSignature(Map<String, String> params) {
    final joined =
        params.entries.map((e) => '${e.key}=${e.value}').toList()..sort();
    final raw = '$_salt${joined.join()}$_salt';
    return crypto.md5.convert(utf8.encode(raw)).toString();
  }

  /// 发起带全量签名参数的 GET，返回解码后的 JSON。
  ///
  /// **网络层异常原样透传 [DioException]**：通用扫码登录页把
  /// [NetworkSourceException] 视为「明确失败」并停止轮询，
  /// 若把瞬时断网/超时包装成它，一次抖动就会终止整个扫码流程。
  /// 透传后由调用方的通用 `catch` 走静默重试（与网易云一致）。
  Future<dynamic> _signedGet(String url, Map<String, String> params) async {
    final signature = _webSignature(params);
    final response = await _dio.get<String>(
      url,
      queryParameters: <String, dynamic>{...params, 'signature': signature},
      options: Options(responseType: ResponseType.plain),
    );
    return _decoded(response);
  }

  Track? _trackFromSearchSong(dynamic raw) {
    final song = _asMap(raw);
    if (song == null) return null;
    final hash = asStringOrNull(song['FileHash']);
    if (hash == null || hash.isEmpty) return null;
    String cleanName(String rawName) =>
        rawName.replaceAll('<em>', '').replaceAll('</em>', '').trim();
    final name = cleanName(asStringOrNull(song['SongName']) ?? '');
    if (name.isEmpty) return null;
    final singer = (asStringOrNull(song['SingerName']) ?? '').trim();
    final image = asStringOrNull(song['Image']);
    final durationSec = asIntOrNull(song['Duration']);
    final albumId = asStringOrNull(song['AlbumID']);
    final coverUrl =
        (image == null || image.isEmpty)
            ? null
            : image.replaceAll('{size}', '240').toHttps();
    return Track(
      id: hash,
      sourceId: sourceId,
      title: name,
      artist: singer.isEmpty ? '未知歌手' : singer,
      album: (asStringOrNull(song['AlbumName']) ?? '').trim(),
      duration: durationSec == null ? null : Duration(seconds: durationSec),
      coverUrl: coverUrl,
      sourceData: <String, dynamic>{
        'hash': hash,
        if (albumId != null) 'albumId': albumId,
      },
    );
  }

  dynamic _decoded(Response<dynamic> response) =>
      decodeResponseBody(response.data);

  Map<String, dynamic>? _asMap(dynamic value) => asMap(value);
}
