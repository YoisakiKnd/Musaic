import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
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

/// QQ 音乐渠道。
///
/// 匿名能力：搜索 / LRC 歌词；
/// 登录能力：ptlogin 扫码（QQ 互联 OAuth）→ musicu.fcg 凭据交换，
/// 登录后 vkey 播放解锁 VIP 曲目试听与更高音质（视账号权益）。
class QqMusicSource extends MusicSource {
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
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 10),
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
    final songMid = track.sourceData?['songmid'] as String? ?? track.id;
    if (songMid.isEmpty) {
      throw UnavailableStreamException('曲目缺少渠道标识', sourceId: sourceId);
    }
    String uin = '0';
    try {
      final credentials = await credentialReader();
      uin = credentials['uin'] ?? credentials['qqmusic_u'] ?? '0';
    } catch (_) {}
    final guid = _deviceGuid;
    try {
      final response = await _dio.post<dynamic>(
        'https://u.y.qq.com/cgi-bin/musicu.fcg',
        data: <String, dynamic>{
          'req': <String, dynamic>{
            'module': 'vkey.GetVkeyServer',
            'method': 'CgiGetVkey',
            'param': <String, dynamic>{
              'guid': guid,
              'songmid': <String>[songMid],
              'songtype': <int>[0],
              'uin': uin,
              'loginflag': 1,
              'platform': '20',
            },
          },
        },
        options: Options(responseType: ResponseType.plain),
      );
      final data = _asMap(_decoded(response));
      final midurlInfo =
          _asMap(data?['data'])?['midurlinfo'] as List<dynamic>?;
      final item =
          midurlInfo == null || midurlInfo.isEmpty ? null : _asMap(midurlInfo.first);
      final purl = item?['purl'] as String? ?? '';
      if (purl.isEmpty) {
        throw UnavailableStreamException(
          '该曲目暂不可播放（可能需要会员）',
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

  /// 稳定设备标识（登录态下同一设备复用）。
  String get _deviceGuid =>
      _guidCache ??= List.generate(
        32,
        (_) => '0123456789abcdef'[_random.nextInt(16)],
      ).join();

  String? _guidCache;

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

  // ---------- 真实登录（ptlogin 扫码 / QQ 互联 OAuth） ----------

  /// 步骤 1：获取登录二维码（PNG 字节 + qrsig 会话标识）。
  Future<({Uint8List png, String qrsig})> createQrLogin() async {
    final response = await _dio.get<List<int>>(
      'https://ssl.ptlogin2.qq.com/ptqrshow',
      queryParameters: <String, dynamic>{
        'appid': '716027609',
        'e': '2',
        'l': 'M',
        's': '3',
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
      throw NetworkSourceException('获取登录二维码失败', sourceId: sourceId);
    }
    return (png: png, qrsig: qrsig);
  }

  /// 步骤 2：轮询二维码状态。
  ///
  /// 未扫码 66 → waiting；已扫待确认 67 → scanned；失效 65 → expired；
  /// 成功 0 → 继续步骤 3-6 换取 QQ 音乐凭据后返回 success。
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
        if (args.length < 3) {
          return const QrLoginPollExpired();
        }
        final sigx = RegExp(r'(?:\?|&)ptsigx=(.+?)&s_url').firstMatch(args[2]);
        final uin = RegExp(r'(?:\?|&)uin=(.+?)&service').firstMatch(args[2]);
        if (sigx == null || uin == null) {
          throw NetworkSourceException('登录参数解析失败', sourceId: sourceId);
        }
        return _exchangeCredential(
          uin: uin.group(1)!,
          sigx: sigx.group(1)!,
        );
      default:
        return const QrLoginPollWaiting();
    }
  }

  /// 步骤 3-6：check_sig → oauth authorize → musicu.fcg 凭据交换。
  Future<QrLoginPoll> _exchangeCredential({
    required String uin,
    required String sigx,
  }) async {
    // 步骤 3：check_sig，换取 p_skey 等域 Cookie
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
    final pskey = authCookies['p_skey'] ??
        authCookies['p-skey'] ??
        authCookies['pskey'];
    if (pskey == null || pskey.isEmpty) {
      developer.log('check_sig 未返回 p_skey', name: 'MusaicQQ');
      throw NetworkSourceException('QQ 授权确认失败，请重试', sourceId: sourceId);
    }

    // 步骤 4：oauth authorize 换取授权 code
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
    final codeMatch =
        RegExp(r'(?<=code=)(.+?)(?=&)').firstMatch(location);
    final authCode = codeMatch?.group(1);
    if (authCode == null || authCode.isEmpty) {
      developer.log('oauth authorize 未返回 code: $location', name: 'MusaicQQ');
      throw NetworkSourceException('QQ 授权失败，请重新扫码', sourceId: sourceId);
    }

    // 步骤 5：musicu.fcg QQConnectLogin.QQLogin 换取音乐凭据
    final loginResp = await _dio.post<dynamic>(
      'https://u.y.qq.com/cgi-bin/musicu.fcg',
      data: <String, dynamic>{
        'comm': <String, dynamic>{'tmeLoginType': 2},
        'req': <String, dynamic>{
          'module': 'QQConnectLogin.LoginServer',
          'method': 'QQLogin',
          'param': <String, dynamic>{'code': authCode},
        },
      },
      options: Options(responseType: ResponseType.plain),
    );
    final loginData = _asMap(_decoded(loginResp));
    final inner = _asMap(loginData)?['req'];
    final body = _asMap(inner)?['data'];
    final musicid = body?['musicid'];
    final musickey = body?['musickey'] as String?;
    final encryptUin = body?['encryptUin'] as String? ??
        body?['strMusicid']?.toString() ??
        '';
    if (musicid == null ||
        musickey == null ||
        musickey.isEmpty ||
        musicid.toString().isEmpty) {
      throw NetworkSourceException('凭据交换失败，请重新扫码', sourceId: sourceId);
    }

    // 步骤 6：拉取昵称（失败不阻塞登录）
    String? nickname;
    try {
      nickname = await _fetchNickname(
        musicid: musicid.toString(),
        musickey: musickey,
      );
    } catch (_) {}

    return QrLoginPoll.success(
      credentials: <String, String>{
        'uin': musicid.toString(),
        'qqmusic_u': musicid.toString(),
        'qqmusic_key': musickey,
        'qm_keyst': musickey,
        if (encryptUin.isNotEmpty) 'euin': encryptUin,
      },
      nickname: nickname,
    );
  }

  Future<String?> _fetchNickname({
    required String musicid,
    required String musickey,
  }) async {
    final response = await _dio.get<dynamic>(
      'https://c.y.qq.com/rfc/cgi-bin/musicu.fcg',
      queryParameters: <String, dynamic>{
        'data': jsonEncode(<String, dynamic>{
          'req': <String, dynamic>{
            'module': 'music.userInfo.UserInfoServer',
            'method': 'GetUserInfo',
            'param': <String, dynamic>{},
          },
        }),
      },
      options: Options(
        responseType: ResponseType.plain,
        headers: <String, String>{
          'Cookie': 'uin=$musicid; qqmusic_u=$musicid; '
              'qqmusic_key=$musickey; qm_keyst=$musickey',
        },
      ),
    );
    final data = _asMap(_decoded(response));
    final nick = _asMap(
          _asMap(_asMap(data)?['req'])?['data'],
        )?['nick'] as String?;
    return (nick == null || nick.isEmpty) ? null : nick;
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
    try {
      final credentials = await credentialReader();
      final key = credentials['qqmusic_key'];
      final uin = credentials['uin'] ?? credentials['qqmusic_u'];
      if (key == null || key.isEmpty || uin == null || uin.isEmpty) {
        return false;
      }
      final nickname = await _fetchNickname(musicid: uin, musickey: key);
      return nickname != null;
    } catch (_) {
      return false;
    }
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
