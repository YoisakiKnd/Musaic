import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import '../../core/error/source_exception.dart';
import '../../core/model/track.dart';
import '../../core/network/network_config.dart';
import '../../core/network/source_auth_interceptor.dart';
import '../../core/source/capabilities.dart';
import '../../core/source/music_source.dart';
import '../../core/auth/auth_capability.dart';
import '../../core/auth/auth_result.dart';
import '../../core/auth/qr_login_poll.dart';
import '../../core/auth/source_account.dart';
import '../../core/lyrics/lrc_parser.dart';
import '../../core/lyrics/lyric_bundle.dart';

/// QQ 音乐渠道。
///
/// 匿名能力：搜索 / LRC 歌词；
/// 登录能力：ptlogin 扫码（QQ 互联 OAuth）与微信扫码双通道
/// （[QrLoginCapable]，UI 零改动）→ musicu.fcg 凭据交换，
/// 登录后 vkey 播放解锁 VIP 曲目试听与更高音质（视账号权益）。
class QqMusicSource extends MusicSource implements QrLoginCapable {
  QqMusicSource({
    required super.credentialReader,
    this.onSessionExpired,
  });

  static const String id = 'qqmusic';

  /// 会话过期回调（由组合根接 AccountNotifier）。
  final void Function()? onSessionExpired;

  @override
  String get sourceId => QqMusicSource.id;

  @override
  String get displayName => 'QQ 音乐';

  @override
  AuthCapability get authCapability => AuthCapability.noAuth;

  final Random _random = Random.secure();

  late final Dio _dio = _buildDio();

  Dio _buildDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: NetworkConfig.instance.connect,
        receiveTimeout: NetworkConfig.instance.receive,
        headers: <String, String>{
          'Referer': 'https://y.qq.com/',
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
              'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 '
              'Safari/537.36',
        },
        validateStatus: (int? code) => code != null && code < 500,
      ),
    );
    dio.interceptors.add(
      SourceAuthInterceptor(
        sourceId: QqMusicSource.id,
        readCredentials: credentialReader,
        onSessionExpired: () => onSessionExpired?.call(),
      ),
    );
    dio.interceptors.add(TimeoutInterceptor());
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
      final tracks = songs
          .map(_trackFromSmartboxItem)
          .whereType<Track>()
          .toList(growable: false);
      // smartbox 不带封面：并发补拉专辑图（失败静默，不阻塞搜索）
      return _enrichCovers(tracks);
    } on DioException {
      throw NetworkSourceException('搜索失败：网络异常', sourceId: sourceId);
    }
  }

  /// smartbox 结果补专辑封面（songmid → 单曲详情 → album mid → 封面 URL）。
  Future<List<Track>> _enrichCovers(List<Track> tracks) async {
    final enriched = await Future.wait(
      tracks.map((track) async {
        try {
          final songMid = track.sourceData?['songmid'] as String? ?? track.id;
          final response = await _dio.get<dynamic>(
            'https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg',
            queryParameters: <String, dynamic>{
              'songmid': songMid,
              'platform': 'yqq',
              'format': 'json',
            },
            options: Options(responseType: ResponseType.plain),
          );
          final list = _decoded(response) as List<dynamic>? ??
              _asMap(_decoded(response))?['data'] as List<dynamic>?;
          if (list == null || list.isEmpty) return track;
          final albumMid =
              _asMap(_asMap(list.first)?['album'])?['mid'] as String?;
          if (albumMid == null || albumMid.isEmpty) return track;
          return track.copyWith(
            album: _asMap(_asMap(list.first)?['album'])?['name'] as String? ??
                track.album,
            coverUrl:
                'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg',
          );
        } catch (_) {
          return track;
        }
      }),
      eagerError: false,
    );
    return enriched;
  }

  @override
  Future<Track> getTrackDetail(Track track) async =>
      track; // 搜索结果已含全部展示字段

  @override
  Future<ResolvedStream> resolveStream(Track track) async {
    final songMid = track.sourceData?['songmid'] as String? ?? track.id;
    if (songMid.isEmpty) {
      throw UnavailableStreamException('曲目缺少渠道标识', sourceId: sourceId);
    }
    String uin = '0';
    String musickey = '';
    bool loggedIn = false;
    try {
      final credentials = await credentialReader();
      uin = credentials['uin'] ?? credentials['qqmusic_u'] ?? '0';
      musickey = credentials['musickey'] ?? credentials['qqmusic_key'] ?? '';
      loggedIn = uin.isNotEmpty && uin != '0' && musickey.isNotEmpty;
    } catch (_) {}
    final comm = _androidComm(
      tmeLoginType: 2,
      uin: loggedIn ? uin : null,
      musickey: loggedIn ? musickey : null,
    );
    try {
      final data = await _musicuCgi(
        module: 'vkey.GetVkeyServer',
        method: 'CgiGetVkey',
        param: <String, dynamic>{
          'guid': _deviceGuid,
          'songmid': <String>[songMid],
          'songtype': <int>[0],
          'uin': uin,
          'loginflag': 1,
          'platform': '20',
        },
        comm: comm,
      );
      final midurlInfo = data?['midurlinfo'] as List<dynamic>?;
      final item = midurlInfo == null || midurlInfo.isEmpty
          ? null
          : _asMap(midurlInfo.first);
      final purl = item?['purl'] as String? ?? '';
      if (purl.isEmpty) {
        throw UnavailableStreamException(
          loggedIn
              ? '受版权方限制，该曲目暂不可播放（可能需要会员）'
              : '该曲目需要登录后播放，请先在「设置 → 账号管理」登录 QQ 音乐',
          sourceId: sourceId,
        );
      }
      return ResolvedStream(
        url: purl.startsWith('http')
            ? purl
            : 'https://dl.stream.qq.music.qq/$purl',
        headers: <String, String>{'Referer': 'https://y.qq.com/'},
      );
    } on DioException {
      throw NetworkSourceException(
        '获取播放地址失败：网络异常',
        sourceId: sourceId,
      );
    }
  }

  // ---------- musicu.fcg 统一调用 ----------

  /// Android 端 comm 公共参数（对照 luren-dc/QQMusicApi build_comm）。
  ///
  /// 登录交换时 QIMEI 允许为空串；已登录调用带 qq + authst(musickey)。
  Map<String, dynamic> _androidComm({
    required int tmeLoginType,
    String? uin,
    String? musickey,
  }) {
    return <String, dynamic>{
      'ct': 11,
      'cv': 14090008,
      'v': 14090008,
      'chid': '10003505',
      if (uin != null && uin.isNotEmpty) 'qq': uin,
      if (musickey != null && musickey.isNotEmpty) 'authst': musickey,
      'tmeAppID': 'qqmusic',
      'tmeLoginType': tmeLoginType,
      'QIMEI': '',
      'QIMEI36': '',
      'OpenUDID': _deviceGuid,
      'udid': _deviceGuid,
      'OpenUDID2': _deviceGuid,
      'uid': _sessionUid,
      'sid': _sessionSid,
      'aid': _androidId,
      'os_ver': '14',
      'phonetype': 'Musaic',
      'devicelevel': '34',
      'newdevicelevel': '34',
      'rom': 'Musaic/android_14',
    };
  }

  /// musicu.fcg 统一 POST；返回 req.data（业务码异常仅记日志）。
  Future<Map<String, dynamic>?> _musicuCgi({
    required String module,
    required String method,
    required Map<String, dynamic> param,
    Map<String, dynamic>? comm,
  }) async {
    final response = await _dio.post<dynamic>(
      'https://u.y.qq.com/cgi-bin/musicu.fcg',
      data: <String, dynamic>{
        if (comm != null) 'comm': comm,
        'req': <String, dynamic>{
          'module': module,
          'method': method,
          'param': param,
        },
      },
      options: Options(responseType: ResponseType.plain),
    );
    final outer = _asMap(_decoded(response));
    final req = _asMap(outer)?['req'];
    final code = _asMap(req)?['code'] as int? ?? -1;
    if (code != 0 && code != 2000) {
      developer.log('$module.$method 业务码 $code', name: 'MusaicQQ');
    }
    final data = _asMap(req)?['data'];
    return data is Map<String, dynamic> ? data : null;
  }

  /// 稳定设备标识（登录态下同一设备复用）。
  String get _deviceGuid =>
      _guidCache ??= List.generate(
        32,
        (_) => '0123456789abcdef'[_random.nextInt(16)],
      ).join();

  String? _guidCache;

  String get _sessionUid => _sessionUidCache ??= _randomHex(16);
  String get _sessionSid => _sessionSidCache ??= _randomHex(16);
  String get _androidId => _androidIdCache ??= _randomHex(16);

  String? _sessionUidCache;
  String? _sessionSidCache;
  String? _androidIdCache;

  String _randomHex(int length) => List.generate(
        length,
        (_) => '0123456789abcdef'[_random.nextInt(16)],
      ).join();

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

  // ---------- 真实登录（QQ音乐扫码：QQ / 微信双通道） ----------
  //
  // QQ 通道：ptlogin 二维码（手机 QQ 扫码）→ check_sig → oauth authorize →
  //          musicu.fcg QQConnectLogin.QQLogin 凭据交换；
  // 微信通道：open.weixin.qq.com 二维码（微信扫码）→ 长轮询 code →
  //          musicu.fcg music.login.LoginServer.Login 凭据交换。
  // 两通道均对照 luren-dc/QQMusicApi 参考实现。

  @override
  List<QrLoginFlow> get qrLoginFlows => [
        QrLoginFlow(
          id: 'qq',
          label: 'QQ 扫码',
          scanHint: '请使用手机 QQ「扫一扫」并确认登录',
          create: () async {
            final session = await createQrLogin();
            return QrLoginSession(pollKey: session.qrsig, png: session.png);
          },
          poll: (session) => pollQrLogin(session.pollKey),
          userIdCredentialKey: 'uin',
          fallbackNickname: 'QQ 音乐用户',
          footerHint: '扫码登录后可播放会员曲目并同步账号歌单',
        ),
        QrLoginFlow(
          id: 'wechat',
          label: '微信扫码',
          scanHint: '请使用微信「扫一扫」并确认登录',
          interval: const Duration(milliseconds: 1500),
          create: () async {
            final session = await createWxQrLogin();
            return QrLoginSession(pollKey: session.uuid, png: session.png);
          },
          poll: (session) => pollWxQrLogin(session.pollKey),
          userIdCredentialKey: 'uin',
          fallbackNickname: 'QQ 音乐用户',
          footerHint: '微信扫码登录后可同步会员权益与账号歌单',
        ),
      ];

  /// 创建 QQ 扫码登录会话（PNG 字节 + qrsig）。
  Future<({Uint8List png, String qrsig})> createQrLogin() async {
    final response = await _dio.get<List<int>>(
      'https://ssl.ptlogin2.qq.com/ptqrshow',
      queryParameters: <String, dynamic>{
        'appid': '716027609',
        'e': '2',
        'l': 'M',
        // s=7 → 官方 259px PNG；s=3 仅 111px，铺到 200pt 显得过小
        's': '7',
        'd': '72',
        'v': '4',
        't': _random.nextDouble().toString(),
        'daid': '383',
        'pt_3rd_aid': '100497308',
      },
      options: Options(
        responseType: ResponseType.bytes,
        headers: <String, String>{
          'Referer': 'https://xui.ptlogin2.qq.com/',
        },
      ),
    );
    final png = Uint8List.fromList(response.data ?? const <int>[]);
    final qrsig = _cookieFrom(response, 'qrsig');
    if (png.isEmpty || qrsig == null || qrsig.isEmpty) {
      developer.log(
        'ptqrshow 失败: status=${response.statusCode} pngLen=${png.length}',
        name: 'MusaicQQ',
      );
      throw NetworkSourceException('获取登录二维码失败', sourceId: sourceId);
    }
    return (png: png, qrsig: qrsig);
  }

  /// 创建微信扫码登录会话（JPEG 字节 + uuid）。
  Future<({Uint8List png, String uuid})> createWxQrLogin() async {
    final page = await _dio.get<String>(
      'https://open.weixin.qq.com/connect/qrconnect',
      queryParameters: <String, dynamic>{
        'appid': 'wx48db31d50e334801',
        'redirect_uri':
            'https://y.qq.com/portal/wx_redirect.html?login_type=2'
                '&surl=https://y.qq.com/',
        'response_type': 'code',
        'scope': 'snsapi_login',
        'state': 'STATE',
        'href':
            'https://y.qq.com/mediastyle/music_v17/src/css/popup_wechat.css'
                '#wechat_redirect',
      },
      options: Options(responseType: ResponseType.plain),
    );
    final html = page.data ?? '';
    final match = RegExp('uuid=(.+?)"').firstMatch(html);
    final uuid = match?.group(1);
    if (uuid == null || uuid.isEmpty) {
      developer.log('微信二维码 uuid 提取失败 len=${html.length}',
          name: 'MusaicQQ');
      throw NetworkSourceException('获取微信二维码失败', sourceId: sourceId);
    }
    final img = await _dio.get<List<int>>(
      'https://open.weixin.qq.com/connect/qrcode/$uuid',
      options: Options(
        responseType: ResponseType.bytes,
        headers: <String, String>{
          'Referer': 'https://open.weixin.qq.com/connect/qrconnect',
        },
      ),
    );
    final png = Uint8List.fromList(img.data ?? const <int>[]);
    if (png.isEmpty) {
      throw NetworkSourceException('获取微信二维码失败', sourceId: sourceId);
    }
    return (png: png, uuid: uuid);
  }

  /// 轮询 QQ 二维码状态：66 等待 / 67 已扫 / 65 过期 / 0 成功。
  Future<QrLoginPoll> pollQrLogin(String qrsig) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final response = await _dio.get<String>(
      'https://ssl.ptlogin2.qq.com/ptqrlogin',
      queryParameters: <String, dynamic>{
        'u1': 'https://graph.qq.com/oauth2.0/login_jump',
        'ptqrtoken': _hash33(qrsig),
        'ptredirect': '0',
        'h': '1',
        't': '1',
        'g': '1',
        'from_ui': '1',
        'ptlang': '2052',
        'action': '0-0-$ts',
        'js_ver': '20102616',
        'js_type': '1',
        'pt_uistyle': '40',
        'aid': '716027609',
        'daid': '383',
        'pt_3rd_aid': '100497308',
        'has_onekey': '1',
      },
      options: Options(
        responseType: ResponseType.plain,
        headers: <String, String>{
          'Referer': 'https://xui.ptlogin2.qq.com/',
          'Cookie': 'qrsig=$qrsig',
        },
      ),
    );
    final body = response.data ?? '';
    final args = _parsePtuiCb(body);
    if (args == null || args.isEmpty) {
      developer.log('ptqrlogin 响应异常: ${body.trim().substring(0, body.trim().length.clamp(0, 120))}',
          name: 'MusaicQQ');
      throw NetworkSourceException('二维码状态解析失败', sourceId: sourceId);
    }
    final code = int.tryParse(args[0]) ?? -1;
    switch (code) {
      case 66:
        return const QrLoginPollWaiting();
      case 67:
        return const QrLoginPollScanned();
      case 65:
        return const QrLoginPollExpired();
      case 0:
        if (args.length < 3) return const QrLoginPollExpired();
        final sigx =
            RegExp(r'(?:\?|&)ptsigx=(.+?)&s_url').firstMatch(args[2]);
        final uin =
            RegExp(r'(?:\?|&)uin=(.+?)&service').firstMatch(args[2]);
        if (sigx == null || uin == null) {
          developer.log('回调参数解析失败: ${args[2].substring(0, args[2].length.clamp(0, 200))}',
              name: 'MusaicQQ');
          throw NetworkSourceException('登录参数解析失败', sourceId: sourceId);
        }
        return _exchangeQqCredential(
          uin: uin.group(1)!,
          sigx: sigx.group(1)!,
        );
      default:
        return const QrLoginPollWaiting();
    }
  }

  /// 轮询微信二维码状态（长轮询，单次最长约 25s）。
  ///
  /// 408 等待 / 405 已确认（含 code）/ 404 过期 / 402 已取消。
  Future<QrLoginPoll> pollWxQrLogin(String uuid) async {
    final Response<String> response;
    try {
      response = await _dio.get<String>(
        'https://lp.open.weixin.qq.com/connect/l/qrconnect',
        queryParameters: <String, dynamic>{
          'uuid': uuid,
          '_': '${DateTime.now().millisecondsSinceEpoch}',
        },
        options: Options(
          responseType: ResponseType.plain,
          headers: <String, String>{
            'Referer': 'https://open.weixin.qq.com/',
          },
        ),
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionTimeout) {
        return const QrLoginPollWaiting(); // 长轮询超时 = 继续等待
      }
      rethrow;
    }
    final body = response.data ?? '';
    final match = RegExp(
      r"window\.wx_errcode=(\d+);window\.wx_code='([^']*)'",
    ).firstMatch(body);
    if (match == null) {
      developer.log('微信轮询响应异常: ${body.substring(0, body.length.clamp(0, 120))}',
          name: 'MusaicQQ');
      return const QrLoginPollWaiting();
    }
    final errcode = int.tryParse(match.group(1)!) ?? -1;
    final wxCode = match.group(2) ?? '';
    switch (errcode) {
      case 408:
      case 409:
        return const QrLoginPollWaiting();
      case 405:
        if (wxCode.isEmpty) {
          throw NetworkSourceException('微信授权失败（code 为空）',
              sourceId: sourceId);
        }
        return _exchangeWxCredential(wxCode);
      case 404:
        return const QrLoginPollExpired();
      case 402:
        throw NetworkSourceException('微信授权被取消', sourceId: sourceId);
      default:
        return const QrLoginPollWaiting();
    }
  }

  /// QQ 通道凭据交换：check_sig → oauth authorize → QQLogin。
  Future<QrLoginPoll> _exchangeQqCredential({
    required String uin,
    required String sigx,
  }) async {
    // 步骤 1：check_sig，换取 p_skey 等域 Cookie
    final checkResp = await _dio.get<dynamic>(
      'https://ssl.ptlogin2.graph.qq.com/check_sig',
      queryParameters: <String, dynamic>{
        'uin': uin,
        'pttype': '1',
        'service': 'ptqrlogin',
        'nodirect': '0',
        'ptsigx': sigx,
        's_url': 'https://graph.qq.com/oauth2.0/login_jump',
        'ptlang': '2052',
        'ptredirect': '100',
        'aid': '716027609',
        'daid': '383',
        'j_later': '0',
        'low_login_hour': '0',
        'regmaster': '0',
        'pt_login_type': '3',
        'pt_aid': '0',
        'pt_aaid': '16',
        'pt_light': '0',
        'pt_3rd_aid': '100497308',
      },
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: false,
        validateStatus: (int? code) => code != null && code < 400,
        headers: <String, String>{
          'Referer': 'https://xui.ptlogin2.qq.com/',
        },
      ),
    );
    final authCookies = _cookiesFrom(checkResp);
    developer.log(
      'check_sig status=${checkResp.statusCode} '
      'cookies=${authCookies.keys.toList()}',
      name: 'MusaicQQ',
    );
    final pskey =
        authCookies['p_skey'] ?? authCookies['p-skey'] ?? authCookies['pskey'];
    if (pskey == null || pskey.isEmpty) {
      throw NetworkSourceException('QQ 授权确认失败（未取得 p_skey），请重试',
          sourceId: sourceId);
    }

    // 步骤 2：oauth authorize 换取授权 code
    final cookieHeader = authCookies.entries
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
    final authResp = await _dio.post<dynamic>(
      'https://graph.qq.com/oauth2.0/authorize',
      data: <String, String>{
        'response_type': 'code',
        'client_id': '100497308',
        'redirect_uri':
            'https://y.qq.com/portal/wx_redirect.html?login_type=1'
                '&surl=https://y.qq.com/',
        'scope': 'get_user_info,get_app_friends',
        'state': 'state',
        'switch': '',
        'from_ptlogin': '1',
        'src': '1',
        'update_auth': '1',
        'openapi': '1010_1030',
        'g_tk': '${_hash33(pskey, 5381)}',
        'auth_time': '${DateTime.now().millisecondsSinceEpoch}',
        'ui': '${_randomHex(8).substring(0, 8)}-musaic',
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        responseType: ResponseType.plain,
        followRedirects: false,
        validateStatus: (int? code) => code != null && code < 400,
        headers: <String, String>{
          'Referer': 'https://xui.ptlogin2.qq.com/',
          'Cookie': cookieHeader,
        },
      ),
    );
    final location = authResp.headers.value('location') ?? '';
    developer.log('authorize status=${authResp.statusCode} '
        'location=${location.substring(0, location.length.clamp(0, 120))}',
        name: 'MusaicQQ');
    final codeMatch =
        RegExp(r'(?<=code=)(.+?)(?=&)').firstMatch(location);
    final authCode = codeMatch?.group(1);
    if (authCode == null || authCode.isEmpty) {
      throw NetworkSourceException('QQ 授权失败，请重新扫码', sourceId: sourceId);
    }

    // 步骤 3：musicu.fcg QQConnectLogin.QQLogin（完整 Android comm）
    final data = await _musicuCgi(
      module: 'QQConnectLogin.LoginServer',
      method: 'QQLogin',
      param: <String, dynamic>{'code': authCode},
      comm: _androidComm(tmeLoginType: 2),
    );
    return _credentialFromLoginData(data, fallbackNickname: null);
  }

  /// 微信通道凭据交换：music.login.LoginServer/Login。
  Future<QrLoginPoll> _exchangeWxCredential(String wxCode) async {
    final data = await _musicuCgi(
      module: 'music.login.LoginServer',
      method: 'Login',
      param: <String, dynamic>{
        'code': wxCode,
        'strAppid': 'wx48db31d50e334801',
      },
      comm: _androidComm(tmeLoginType: 1),
    );
    return _credentialFromLoginData(data, fallbackNickname: null);
  }

  /// 从凭据交换响应提取账号；成功后顺带拉取昵称与会员状态。
  Future<QrLoginPoll> _credentialFromLoginData(
    Map<String, dynamic>? data, {
    required String? fallbackNickname,
  }) async {
    final musicid = data?['musicid'];
    final musickey = data?['musickey'] as String?;
    final encryptUin = data?['encryptUin'] as String? ?? '';
    if (musicid == null ||
        musicid.toString().isEmpty ||
        musickey == null ||
        musickey.isEmpty) {
      developer.log('凭据交换响应异常: ${data?.keys.toList()}',
          name: 'MusaicQQ');
      throw NetworkSourceException('凭据交换失败，请重新扫码', sourceId: sourceId);
    }
    final credentials = <String, String>{
      'uin': musicid.toString(),
      'qqmusic_u': musicid.toString(),
      'musickey': musickey,
      'qqmusic_key': musickey,
      'qm_keyst': musickey,
      if (encryptUin.isNotEmpty) 'euin': encryptUin,
    };

    // 拉取昵称（会员状态由账号页刷新时展示；失败不阻塞登录）
    String? nickname;
    try {
      final info = await fetchAccountSummary(credentials: credentials);
      nickname = info?.nickname;
    } catch (_) {}

    return QrLoginPoll.success(
      credentials: credentials,
      nickname: nickname ?? fallbackNickname,
    );
  }

  /// 拉取 QQ 音乐账号昵称与会员状态。
  ///
  /// [strict] 为 true 时，主页头接口网络异常将抛出（供 checkSession
  /// 区分「断网」与「凭据失效」）；默认吞掉保持资料展示不阻塞。
  Future<({String nickname, String? vipLabel})?>
      fetchAccountSummary({
    Map<String, String>? credentials,
    bool strict = false,
  }) async {
    Map<String, String> cred;
    if (credentials != null) {
      cred = credentials;
    } else {
      cred = await credentialReader();
    }
    final uin = cred['uin'] ?? cred['qqmusic_u'] ?? '';
    final musickey = cred['musickey'] ?? cred['qqmusic_key'] ?? '';
    final euin = cred['euin'] ?? '';
    if (uin.isEmpty || musickey.isEmpty) return null;
    final comm = _androidComm(
      tmeLoginType: 2,
      uin: uin,
      musickey: musickey,
    );

    String nickname = '';
    Future<String> readNickname() async {
      final header = await _musicuCgi(
        module: 'music.UnifiedHomepage.UnifiedHomepageSrv',
        method: 'GetHomepageHeader',
        param: <String, dynamic>{
          'uin': euin.isNotEmpty ? euin : uin,
          'IsQueryTabDetail': 1,
        },
        comm: comm,
      );
      return (_asMap(header?['Info'])?['BaseInfo']?['NickName'] as String?) ??
          '';
    }

    if (strict) {
      nickname = await readNickname();
    } else {
      try {
        nickname = await readNickname();
      } catch (_) {}
    }

    String? vipLabel;
    try {
      final vip = await _musicuCgi(
        module: 'VipLogin.VipLoginInter',
        method: 'vip_login_base',
        param: <String, dynamic>{},
        comm: comm,
      );
      final identity = _asMap(vip)?['VipIdentity'] ?? vip;
      final isVip = (identity?['vip'] as num? ?? 0) > 0;
      final isHuge = (identity?['HugeVip'] as num? ?? 0) > 0;
      final level = identity?['level'] as num?;
      if (isHuge) {
        vipLabel = level != null ? '豪华绿钻 Lv$level' : '豪华绿钻';
      } else if (isVip) {
        vipLabel = level != null ? '绿钻 Lv$level' : '绿钻会员';
      }
    } catch (_) {}

    if (nickname.isEmpty && vipLabel == null) return null;
    return (
      nickname: nickname.isEmpty ? 'QQ 音乐用户' : nickname,
      vipLabel: vipLabel,
    );
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

  @override
  Future<AuthResult> login(Map<String, String> credentials) async {
    final key = credentials['qqmusic_key']?.trim() ?? '';
    final uin = credentials['uin']?.trim() ??
        credentials['qqmusic_u']?.trim() ??
        '';
    if (key.isEmpty || uin.isEmpty) {
      return const AuthFailure(
        reason: AuthFailureReason.invalidCredentials,
        message: '请填写完整凭据（uin 与 qqmusic_key）',
      );
    }
    return AuthSuccess(
      SourceAccount.markNow(
        sourceId: sourceId,
        status: AccountStatus.loggedIn,
        userId: uin,
        nickname: 'QQ 音乐用户',
      ),
      credentials: <String, String>{
        'uin': uin,
        'qqmusic_u': uin,
        'qqmusic_key': key,
        'qm_keyst': key,
      },
    );
  }

  @override
  Future<bool> checkSession() async {
    final credentials = await credentialReader();
    final uin = credentials['uin'] ?? credentials['qqmusic_u'] ?? '';
    final musickey =
        credentials['musickey'] ?? credentials['qqmusic_key'] ?? '';
    if (uin.isEmpty || musickey.isEmpty) return false;
    final info =
        await fetchAccountSummary(credentials: credentials, strict: true);
    return info != null;
  }

  // ---------- 工具 ----------

  /// ptlogin hash33：g_tk / ptqrtoken 共用的字符串散列。
  int _hash33(String s, [int h = 0]) {
    for (var i = 0; i < s.length; i++) {
      h = (((h << 5) + h) + s.codeUnitAt(i)) & 0xFFFFFFFF;
      if (h > 0x7FFFFFFF) h -= 0x100000000; // 保持 int32 语义
    }
    return h & 0x7FFFFFFF;
  }

  /// 解析 ptuiCB(...) 回调参数列表。
  List<String>? _parsePtuiCb(String body) {
    final outer =
        RegExp(r'ptuiCB\((.*?)\)', dotAll: true).firstMatch(body.trim());
    if (outer == null) return null;
    return RegExp(r"'((?:\\.|[^'])*)'")
        .allMatches(outer.group(1)!)
        .map((m) => m.group(1)!)
        .toList(growable: false);
  }

  String? _cookieFrom(Response<dynamic> response, String name) {
    for (final raw in response.headers['set-cookie'] ?? const <String>[]) {
      if (raw.startsWith('$name=')) {
        return raw.split(';').first.substring(name.length + 1);
      }
    }
    return null;
  }

  Map<String, String> _cookiesFrom(Response<dynamic> response) {
    final out = <String, String>{};
    for (final raw in response.headers['set-cookie'] ?? const <String>[]) {
      final pair = raw.split(';').first;
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      out[pair.substring(0, eq)] = pair.substring(eq + 1);
    }
    return out;
  }

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
