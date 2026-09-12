import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';

import '../../core/logging/app_logger.dart';
import '../../core/error/source_exception.dart';
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
class KugouSource extends MusicSource implements QrLoginCapable {
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
