import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
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

/// 酷狗音乐渠道。
///
/// 匿名能力：搜索 / 播放直链 / LRC 歌词；
/// 登录能力：h5 二维码扫码（web 签名 MD5 双盐），
/// 成功后凭据为 token/userid，注入 Cookie 解锁完整试听。
class KugouSource extends MusicSource {
  KugouSource({
    required super.credentialReader,
    this.onSessionExpired,
  });

  static const String id = 'kugou';

  /// 会话过期回调（由组合根接 AccountNotifier）。
  final void Function()? onSessionExpired;

  @override
  String get sourceId => KugouSource.id;

  @override
  String get displayName => '酷狗音乐';

  @override
  AuthCapability get authCapability => AuthCapability.noAuth;

  final Random _random = Random.secure();

  /// 设备 MID（32 位 hex，实例生命周期内稳定，参与签名）。
  late final String _mid =
      List.generate(32, (_) => '0123456789abcdef'[_random.nextInt(16)]).join();

  static const String _salt = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';

  late final Dio _dio = _buildDio();

  Dio _buildDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 10),
        headers: <String, String>{
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
        },
        validateStatus: (int? code) => code != null && code < 500,
      ),
    );
    dio.interceptors.add(
      SourceAuthInterceptor(
        sourceId: KugouSource.id,
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

  // ---------- 真实登录（h5 二维码扫码） ----------

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
    final qrKey = _asMap(payload)?['qrcode'] as String?;
    final imgDataUrl = _asMap(payload)?['qrcode_img'] as String?;
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
    final status = _asMap(payload)?['status'] as int? ?? -1;
    switch (status) {
      case 0:
        return const QrLoginPollExpired();
      case 1:
        return const QrLoginPollWaiting();
      case 2:
        return const QrLoginPollScanned();
      case 4:
        final token = _asMap(payload)?['token'] as String?;
        final userid = _asMap(payload)?['userid'];
        if (token == null || token.isEmpty || userid == null) {
          throw NetworkSourceException('登录凭据缺失，请重试', sourceId: sourceId);
        }
        return QrLoginPoll.success(
          credentials: <String, String>{
            'token': token,
            'userid': '$userid',
          },
          nickname: _asMap(payload)?['nickname'] as String?,
        );
      default:
        developer.log('未知二维码状态 $status', name: 'MusaicKugou');
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
    try {
      final credentials = await credentialReader();
      final token = credentials['token'];
      final userid = credentials['userid'];
      if (token == null || token.isEmpty || userid == null) return false;
      return await _fetchNickname(token: token, userid: userid) != null;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _fetchNickname({
    required String token,
    required String userid,
  }) async {
    try {
      final response = await _dio.get<dynamic>(
        'https://userservice.kugou.com/rpc/v1/get_user_info',
        queryParameters: <String, dynamic>{
          'token': token,
          'userid': userid,
        },
        options: Options(responseType: ResponseType.plain),
      );
      final data = _asMap(_decoded(response));
      final userInfo =
          _asMap(_asMap(_asMap(data)?['data'])?['userInfo']);
      final nick = userInfo?['nickname'] as String? ??
          userInfo?['username'] as String?;
      return (nick == null || nick.isEmpty) ? null : nick;
    } catch (_) {
      return null;
    }
  }

  // ---------- 工具 ----------

  String _nowSec() =>
      (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();

  /// web 签名：MD5(salt + 排序后 k=v 拼接 + salt)。
  String _webSignature(Map<String, String> params) {
    final joined = params.entries
        .map((e) => '${e.key}=${e.value}')
        .toList()
      ..sort();
    final raw = '$_salt${joined.join()}$_salt';
    return crypto.md5.convert(utf8.encode(raw)).toString();
  }

  /// 发起带全量签名参数的 GET，返回解码后的 JSON。
  Future<dynamic> _signedGet(String url, Map<String, String> params) async {
    final signature = _webSignature(params);
    try {
      final response = await _dio.get<String>(
        url,
        queryParameters: <String, dynamic>{...params, 'signature': signature},
        options: Options(responseType: ResponseType.plain),
      );
      return _decoded(response);
    } on DioException catch (e) {
      developer.log('signed GET 失败: ${e.type}', name: 'MusaicKugou');
      throw NetworkSourceException('请求失败：网络异常', sourceId: sourceId);
    }
  }

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
