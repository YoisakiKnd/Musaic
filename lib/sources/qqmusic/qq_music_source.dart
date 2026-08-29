import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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
import 'qq_mqtt.dart';

/// QQ 音乐渠道。
///
/// 匿名能力：搜索 / LRC 歌词；
/// 登录：QQ 音乐 App 扫码（CreateQRCode + MQTT）→ musicu.fcg Login
/// （tmeLoginType=6）换 musickey，解锁认证 vkey 播放。
class QqMusicSource extends MusicSource implements QrLoginCapable {
  QqMusicSource({required super.credentialReader, this.onSessionExpired});

  static const String id = 'qqmusic';

  /// 会话过期回调（由组合根接 AccountNotifier）。
  final void Function()? onSessionExpired;

  @override
  String get sourceId => QqMusicSource.id;

  @override
  String get displayName => 'QQ 音乐';

  @override
  AuthCapability get authCapability => AuthCapability.qr;

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
        queryParameters: <String, dynamic>{'key': keyword, 'format': 'json'},
      );
      final songs =
          _asMap(
                _asMap(_asMap(_decoded(response))?['data'])?['song'],
              )?['itemlist']
              as List<dynamic>?;
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
        final songMid = track.sourceData?['songmid'] as String? ?? track.id;
        try {
          final response = await _dio.get<dynamic>(
            'https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg',
            queryParameters: <String, dynamic>{
              'songmid': songMid,
              'platform': 'yqq',
              'format': 'json',
            },
            options: Options(responseType: ResponseType.plain),
          );
          // 响应为 Map（data 列表）或直接的 List；`as List?` 强转在
          // Map 时会抛 TypeError 导致 ?? 兜底永远不走（EMU 实测）
          final decoded = _decoded(response);
          List<dynamic>? list;
          if (decoded is List) {
            list = decoded;
          } else if (decoded is Map) {
            list = _asMap(decoded)?['data'] as List<dynamic>?;
          }
          if (list == null || list.isEmpty) return track;
          final albumMid =
              _asMap(_asMap(list.first)?['album'])?['mid'] as String?;
          if (albumMid == null || albumMid.isEmpty) return track;
          return track.copyWith(
            album:
                _asMap(_asMap(list.first)?['album'])?['name'] as String? ??
                track.album,
            coverUrl:
                'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg',
          );
        } catch (e) {
          developer.log('封面补全失败[$songMid]: $e', name: 'MusaicQQ');
          return track;
        }
      }),
      eagerError: false,
    );
    return enriched;
  }

  @override
  Future<Track> getTrackDetail(Track track) async => track; // 搜索结果已含全部展示字段

  @override
  Future<ResolvedStream> resolveStream(Track track) async {
    final songMid = track.sourceData?['songmid'] as String? ?? track.id;
    if (songMid.isEmpty) {
      throw UnavailableStreamException('曲目缺少渠道标识', sourceId: sourceId);
    }
    String uin = '0';
    String musickey = '';
    var loginType = 6;
    var loggedIn = false;
    try {
      final credentials = await credentialReader();
      uin = credentials['uin'] ?? credentials['qqmusic_u'] ?? '0';
      musickey = credentials['musickey'] ?? credentials['qqmusic_key'] ?? '';
      loginType = int.tryParse(credentials['tmeLoginType'] ?? '') ?? 6;
      loggedIn = uin.isNotEmpty && uin != '0' && musickey.isNotEmpty;
    } catch (_) {}
    final comm = _androidComm(
      tmeLoginType: loginType,
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
      final item =
          midurlInfo == null || midurlInfo.isEmpty
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
        url:
            purl.startsWith('http')
                ? purl
                : 'https://ws.stream.qqmusic.qq.com/$purl',
        headers: <String, String>{'Referer': 'https://y.qq.com/'},
      );
    } on DioException {
      throw NetworkSourceException('获取播放地址失败：网络异常', sourceId: sourceId);
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

  /// musicu.fcg 命名请求（登录用 `req_0`，可跳过凭据注入）。
  Future<Map<String, dynamic>?> _musicuNamed({
    required String reqKey,
    required String module,
    required String method,
    required Map<String, dynamic> param,
    Map<String, dynamic>? comm,
    bool skipAuth = false,
  }) async {
    var options = Options(responseType: ResponseType.plain);
    if (skipAuth) {
      options = SourceAuthInterceptor.skipAuth(options);
    }
    final response = await _dio.post<dynamic>(
      'https://u.y.qq.com/cgi-bin/musicu.fcg',
      data: <String, dynamic>{
        if (comm != null) 'comm': comm,
        reqKey: <String, dynamic>{
          'module': module,
          'method': method,
          'param': param,
        },
      },
      options: options,
    );
    final outer = _asMap(_decoded(response));
    final req = _asMap(outer)?[reqKey];
    final code = _asMap(req)?['code'] as int? ?? -1;
    if (code != 0 && code != 2000) {
      developer.log('$module.$method 业务码 $code', name: 'MusaicQQ');
    }
    final data = _asMap(req)?['data'];
    return data is Map<String, dynamic> ? data : null;
  }

  /// 稳定设备标识（登录态下同一设备复用）。
  String get _deviceGuid =>
      _guidCache ??=
          List.generate(
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

  String _randomHex(int length) =>
      List.generate(
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

  // ---------- 真实登录（QQ 音乐 App 扫码） ----------
  //
  // CreateQRCode 取 PNG + qrcodeID → MQTT 5 等 cookies 事件 →
  // music.login.LoginServer.Login（tmeLoginType=6）换 musickey。

  final Map<String, _QqAppQrWatch> _appQrWatches = <String, _QqAppQrWatch>{};

  @override
  List<QrLoginFlow> get qrLoginFlows => [
    QrLoginFlow(
      id: 'qqmusic-app',
      label: '扫码登录',
      scanHint: '请使用 QQ 音乐 App「扫一扫」并确认登录',
      interval: const Duration(milliseconds: 800),
      create: () async {
        _cancelAllAppQr();
        final session = await _createAppQrLogin();
        return QrLoginSession(pollKey: session.qrcodeId, png: session.png);
      },
      poll: (session) => _pollAppQrLogin(session.pollKey),
      cancel: (session) => _cancelAppQr(session.pollKey),
      userIdCredentialKey: 'uin',
      fallbackNickname: 'QQ 音乐用户',
      footerHint: '扫码登录后可播放会员曲目',
    ),
  ];

  void _cancelAllAppQr() {
    for (final watch in _appQrWatches.values) {
      watch.abort();
    }
    _appQrWatches.clear();
  }

  void _cancelAppQr(String qrcodeId) {
    _appQrWatches.remove(qrcodeId)?.abort();
  }

  Future<({Uint8List png, String qrcodeId})> _createAppQrLogin() async {
    final data = await _musicuNamed(
      reqKey: 'req_0',
      module: 'music.login.LoginServer',
      method: 'CreateQRCode',
      param: <String, dynamic>{'tmeAppID': 'qqmusic', 'ct': 19, 'cv': 2201},
      comm: <String, dynamic>{'ct': 23, 'cv': 0, 'chid': '0'},
      skipAuth: true,
    );
    final qrcode = data?['qrcode'] as String? ?? '';
    final qrcodeId = data?['qrcodeID'] as String? ?? '';
    if (qrcode.isEmpty || qrcodeId.isEmpty) {
      throw NetworkSourceException('获取登录二维码失败', sourceId: sourceId);
    }
    final b64 = qrcode.contains(',') ? qrcode.split(',').last : qrcode;
    final png = Uint8List.fromList(base64.decode(b64.trim()));
    if (png.isEmpty) {
      throw NetworkSourceException('获取登录二维码失败', sourceId: sourceId);
    }
    final watch = _QqAppQrWatch(qrcodeId: qrcodeId);
    _appQrWatches[qrcodeId] = watch;
    unawaited(_watchAppQr(watch));
    return (png: png, qrcodeId: qrcodeId);
  }

  Future<QrLoginPoll> _pollAppQrLogin(String qrcodeId) async {
    final watch = _appQrWatches[qrcodeId];
    if (watch == null) return const QrLoginPollExpired();
    return watch.poll;
  }

  Future<void> _watchAppQr(_QqAppQrWatch watch) async {
    try {
      final clientId =
          '${DateTime.now().millisecondsSinceEpoch}${_random.nextInt(9000) + 1000}';
      final mqtt = await QqMqttClient.connect(
        host: 'mu.y.qq.com',
        path: '/ws/handshake',
        clientId: clientId,
        keepAlive: 45,
        authMethod: 'pass',
        userProperties: <(String, String)>[
          ('tmeAppID', 'qqmusic'),
          ('business', 'management'),
          ('hashTag', watch.qrcodeId),
          ('clientTag', 'management.user'),
          ('userID', watch.qrcodeId),
        ],
      );
      watch.client = mqtt;
      if (watch.aborted) {
        await mqtt.close();
        return;
      }
      await mqtt.subscribe(
        'management.qrcode_login/${watch.qrcodeId}',
        const <(String, String)>[
          ('authorization', 'tmelogin'),
          ('pubsub', 'unicast'),
        ],
      );
      final deadline = DateTime.now().add(const Duration(minutes: 15));
      while (!watch.aborted && DateTime.now().isBefore(deadline)) {
        final publish = await mqtt.nextPublish();
        if (publish == null || watch.aborted) break;
        switch (publish.eventType) {
          case 'scanned':
            if (watch.poll is QrLoginPollWaiting) {
              watch.poll = const QrLoginPollScanned();
            }
          case 'canceled':
            watch.poll = const QrLoginPollExpired();
            watch.abort();
            return;
          case 'timeout':
            watch.poll = const QrLoginPollExpired();
            watch.abort();
            return;
          case 'loginFailed':
            watch.poll = const QrLoginPollExpired();
            watch.abort();
            return;
          case 'cookies':
            final payload = jsonDecode(utf8.decode(publish.payload));
            watch.poll = await _loginWithAppCookies(
              watch.qrcodeId,
              payload is Map ? Map<String, dynamic>.from(payload) : const {},
            );
            watch.abort();
            return;
        }
      }
      if (watch.poll is QrLoginPollWaiting ||
          watch.poll is QrLoginPollScanned) {
        watch.poll = const QrLoginPollExpired();
      }
    } catch (e, st) {
      developer.log('QQ 音乐 App 扫码失败: $e\n$st', name: 'MusaicQQ');
      if (!watch.aborted) {
        watch.poll = const QrLoginPollExpired();
      }
    } finally {
      await watch.client?.close();
    }
  }

  Future<QrLoginPoll> _loginWithAppCookies(
    String qrcodeId,
    Map<String, dynamic> payload,
  ) async {
    final cookies = payload['cookies'];
    if (cookies is! Map) {
      throw NetworkSourceException('扫码凭据缺失', sourceId: sourceId);
    }
    String? cookieValue(String name) {
      final entry = cookies[name];
      if (entry is Map) {
        final value = entry['value'];
        return value == null ? null : '$value';
      }
      if (entry == null) return null;
      return '$entry';
    }

    final uin = cookieValue('qqmusic_uin') ?? '';
    final key = cookieValue('qqmusic_key') ?? '';
    final musicid = int.tryParse(uin);
    if (musicid == null || key.isEmpty) {
      throw NetworkSourceException('扫码凭据不完整', sourceId: sourceId);
    }
    final data = await _musicuNamed(
      reqKey: 'req_0',
      module: 'music.login.LoginServer',
      method: 'Login',
      param: <String, dynamic>{
        'musicid': musicid,
        'qrCodeID': qrcodeId,
        'token': key,
      },
      comm: <String, dynamic>{
        'ct': 19,
        'cv': 2201,
        'chid': '0',
        'tmeLoginType': 6,
      },
      skipAuth: true,
    );
    return _credentialFromLoginData(
      data,
      fallbackNickname: null,
      tmeLoginType: 6,
    );
  }

  /// 从凭据交换响应提取账号；成功后顺带拉取昵称与会员状态。
  Future<QrLoginPoll> _credentialFromLoginData(
    Map<String, dynamic>? data, {
    required String? fallbackNickname,
    int tmeLoginType = 6,
  }) async {
    final musicid = data?['musicid'];
    final musickey = data?['musickey'] as String?;
    final encryptUin = data?['encryptUin'] as String? ?? '';
    if (musicid == null ||
        musicid.toString().isEmpty ||
        musickey == null ||
        musickey.isEmpty) {
      developer.log('凭据交换响应异常: ${data?.keys.toList()}', name: 'MusaicQQ');
      throw NetworkSourceException('凭据交换失败，请重新扫码', sourceId: sourceId);
    }
    final credentials = <String, String>{
      'uin': musicid.toString(),
      'qqmusic_u': musicid.toString(),
      'musickey': musickey,
      'qqmusic_key': musickey,
      'qm_keyst': musickey,
      'tmeLoginType': '$tmeLoginType',
      if (encryptUin.isNotEmpty) 'euin': encryptUin,
    };
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
  Future<({String nickname, String? vipLabel})?> fetchAccountSummary({
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
      tmeLoginType: int.tryParse(cred['tmeLoginType'] ?? '') ?? 6,
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
    return account.copyWith(nickname: info.nickname, vipLabel: info.vipLabel);
  }

  @override
  Future<AuthResult> login(Map<String, String> credentials) async {
    final key = credentials['qqmusic_key']?.trim() ?? '';
    final uin =
        credentials['uin']?.trim() ?? credentials['qqmusic_u']?.trim() ?? '';
    if (key.isEmpty || uin.isEmpty) {
      return const AuthFailure(
        reason: AuthFailureReason.invalidCredentials,
        message: '请填写完整凭据（uin 与 qqmusic_key）',
      );
    }
    final loginType = credentials['tmeLoginType']?.trim() ?? '6';
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
        'musickey': key,
        'qqmusic_key': key,
        'qm_keyst': key,
        'tmeLoginType': loginType.isEmpty ? '6' : loginType,
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
    final info = await fetchAccountSummary(
      credentials: credentials,
      strict: true,
    );
    return info != null;
  }

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
      final jsonpMatch = RegExp(
        r'^[^(]*\((.*)\);?\s*$',
        dotAll: true,
      ).firstMatch(trimmed);
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

class _QqAppQrWatch {
  _QqAppQrWatch({required this.qrcodeId});

  final String qrcodeId;
  QrLoginPoll poll = const QrLoginPollWaiting();
  QqMqttClient? client;
  bool aborted = false;

  void abort() {
    aborted = true;
    final mqtt = client;
    if (mqtt != null) unawaited(mqtt.close());
  }
}
