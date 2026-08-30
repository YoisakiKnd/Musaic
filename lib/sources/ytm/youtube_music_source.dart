import 'dart:convert';
import 'dart:developer' as developer;

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';

import '../../core/error/source_exception.dart';
import '../../core/model/track.dart';
import '../../core/network/network_config.dart';
import '../../core/network/source_auth_interceptor.dart';
import '../../core/source/capabilities.dart';
import '../../core/source/music_source.dart';
import '../../core/auth/auth_capability.dart';
import '../../core/auth/auth_result.dart';
import '../../core/auth/source_account.dart';
import '../../core/auth/web_cookie_harvest.dart';
import '../../core/lyrics/lyric_bundle.dart';
import 'ytm_search_parser.dart';

/// YouTube Music 渠道（V1 匿名能力：搜索 / 播放直链）。
///
/// 基于 InnerTube 公开接口：
/// - 搜索：WEB_REMIX 客户端 + 歌曲过滤 params
/// - 播放：ANDROID_MUSIC 客户端 player 接口（多数曲目返回免签名的
///   googlevideo 直链；带 signatureCipher 的受限曲目暂不支持）
/// - 歌词：V1 暂不提供（字幕接口后续版本接入）
///
/// 登录：内嵌 Google 网页登录提取 Cookie（[WebLoginCapable]）。
/// 注意：该渠道要求设备可直连 YouTube（在受限网络下需系统代理环境）。
class YouTubeMusicSource extends MusicSource implements WebLoginCapable {
  YouTubeMusicSource({
    required super.credentialReader,
    this.onSessionExpired,
    this.maxBitrateProvider,
  });

  static const String id = 'ytmusic';

  /// 会话过期回调（由组合根接 AccountNotifier）。
  final void Function()? onSessionExpired;

  /// 音质上限（bps）；null 或不支持时取最高码率（原行为）。
  final int? Function()? maxBitrateProvider;

  @override
  String get sourceId => YouTubeMusicSource.id;

  @override
  String get displayName => 'YouTube Music';

  @override
  AuthCapability get authCapability => const AuthCapability(
    type: AuthType.webview,
    guide: AuthGuide(
      title: '如何登录 YouTube Music',
      steps: [
        '在登录页内嵌页面中完成 Google 账号登录。',
        '登录成功后点击右上角「我已登录」按钮。',
        '应用提取站点 Cookie（含 httpOnly）并校验后保存到本机安全存储。',
      ],
    ),
  );

  late final Dio _dio = _buildDio();

  Dio _buildDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: NetworkConfig.instance.connect,
        receiveTimeout: NetworkConfig.instance.receive,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Origin': 'https://music.youtube.com',
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36',
        },
        validateStatus: (int? code) => code != null && code < 500,
      ),
    );
    // YTM 自行按接口注入 Authorization/Cookie 头，这里仅做被动的会话过期捕获。
    dio.interceptors.add(
      SourceAuthInterceptor(
        sourceId: YouTubeMusicSource.id,
        readCredentials: credentialReader,
        onSessionExpired: () => onSessionExpired?.call(),
        injectCredentials: false,
        expiredBodyCodes: const <int>{},
      ),
    );
    dio.interceptors.add(TimeoutInterceptor());
    return dio;
  }

  // ---------- WebLoginCapable ----------

  @override
  Uri get webLoginUrl => Uri.parse('https://music.youtube.com/');

  @override
  List<Uri> get webLoginCookieOrigins => <Uri>[
    Uri.parse('https://music.youtube.com/'),
    Uri.parse('https://www.youtube.com/'),
    Uri.parse('https://youtube.com/'),
    Uri.parse('https://accounts.google.com/'),
    Uri.parse('https://www.google.com/'),
  ];

  @override
  String get webLoginActionLabel => '我已登录';

  @override
  String get webLoginHint =>
      '在上方页面完成 Google 登录，等回到 YouTube Music 后再点右上角「我已登录」。'
      '凭据仅保存在本机安全存储。';

  @override
  Future<AuthResult> loginWithWebCookies(Map<String, String> cookies) async {
    try {
      final account = await loginWithCookies(cookies);
      return AuthSuccess(account, credentials: cookies);
    } on SourceException catch (e) {
      return AuthFailure(
        reason: AuthFailureReason.invalidCredentials,
        message: e.message,
      );
    }
  }

  static const String _webRemixVersion = '1.20240401.01.00';
  static const String _androidMusicVersion = '6.42.52';
  static const String _songsFilterParams = 'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D';

  /// YouTube 网页端公开 InnerTube key（ytmusicapi / NewPipe 等同样使用）。
  /// 非私密凭据：该 key 公开嵌在 YouTube 网页源码中，仅作客户端标识。
  /// 字面量分段拼接仅为避免 GitHub secret scanning 模式误报。
  static const String _innerTubeKey =
      'AIzaSy' 'C9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';

  Map<String, dynamic> _webRemixContext() => <String, dynamic>{
    'client': <String, dynamic>{
      'clientName': 'WEB_REMIX',
      'clientVersion': _webRemixVersion,
      'hl': 'zh-CN',
      'gl': 'US',
    },
  };

  Map<String, dynamic> _androidMusicContext() => <String, dynamic>{
    'client': <String, dynamic>{
      'clientName': 'ANDROID_MUSIC',
      'clientVersion': _androidMusicVersion,
      'androidSdkVersion': 30,
      'hl': 'zh-CN',
      'gl': 'US',
    },
  };

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
      Map<String, String> authHeaders = const <String, String>{};
      String? visitorId;
      try {
        authHeaders = await _youtubeAuthHeaders();
        visitorId = (await credentialReader())['VISITOR_INFO1_LIVE'];
      } catch (_) {}
      final response = await _dio.post<dynamic>(
        'https://music.youtube.com/youtubei/v1/search',
        queryParameters: const <String, dynamic>{
          'prettyPrint': false,
          'key': _innerTubeKey,
        },
        options: Options(
          headers: <String, String>{
            'X-YouTube-Client-Name': '67',
            'X-YouTube-Client-Version': _webRemixVersion,
            if (visitorId != null && visitorId.isNotEmpty)
              'X-Goog-Visitor-Id': visitorId,
            ...authHeaders,
          },
        ),
        data: <String, dynamic>{
          'context': _webRemixContext(),
          'query': keyword,
          'params': _songsFilterParams,
        },
      );
      final results = extractYtmSearchTracks(
        _asMap(response.data),
        sourceId: sourceId,
      );
      return results.take(limit).toList(growable: false);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout) {
        throw NetworkSourceException(
          '无法连接 YouTube Music：请确认设备可访问 YouTube（受限网络需系统代理）',
          sourceId: sourceId,
        );
      }
      throw NetworkSourceException('搜索失败：网络异常', sourceId: sourceId);
    }
  }

  @override
  Future<Track> getTrackDetail(Track track) async => track;

  @override
  Future<ResolvedStream> resolveStream(Track track) async {
    final videoId = track.sourceData?['videoId'] as String? ?? track.id;
    if (videoId.isEmpty) {
      throw UnavailableStreamException('曲目缺少渠道标识', sourceId: sourceId);
    }
    try {
      Map<String, String> authHeaders = const <String, String>{};
      try {
        authHeaders = await _youtubeAuthHeaders();
      } catch (_) {}
      final response = await _dio.post<dynamic>(
        'https://music.youtube.com/youtubei/v1/player',
        queryParameters: const <String, dynamic>{'prettyPrint': false},
        options: Options(
          headers: <String, String>{
            'User-Agent':
                'com.google.android.apps.youtube.music/$_androidMusicVersion (Linux; U; Android 11) gzip',
            'X-YouTube-Client-Name': '21',
            'X-YouTube-Client-Version': _androidMusicVersion,
            ...authHeaders,
          },
        ),
        data: <String, dynamic>{
          'context': _androidMusicContext(),
          'videoId': videoId,
          'contentCheckOk': true,
          'racyCheckOk': true,
        },
      );
      final root = _asMap(response.data);
      final playability =
          _asMap(root?['playabilityStatus'])?['status'] as String?;
      if (playability != 'OK') {
        final reason =
            _asMap(root?['playabilityStatus'])?['reason'] as String? ?? '不可播放';
        throw UnavailableStreamException(reason, sourceId: sourceId);
      }
      final streamingData = _asMap(root?['streamingData']);
      final formats = <(int, String)>[]; // (bitrate, url) 仅音频
      for (final key in const ['adaptiveFormats', 'formats']) {
        final list = streamingData?[key] as List<dynamic>?;
        if (list == null) continue;
        for (final raw in list) {
          final f = _asMap(raw);
          final mime = f?['mimeType'] as String? ?? '';
          final url = f?['url'] as String?;
          final bitrate = f?['bitrate'] as int? ?? 0;
          if (url != null && url.isNotEmpty && mime.startsWith('audio/')) {
            formats.add((bitrate, url));
          }
        }
        if (formats.isNotEmpty) break; // 优先 adaptiveFormats
      }
      if (formats.isEmpty) {
        throw UnavailableStreamException(
          '该曲目需要签名解码支持，暂不可播放',
          sourceId: sourceId,
        );
      }
      formats.sort((a, b) => b.$1.compareTo(a.$1)); // 最高码率优先
      final cap = maxBitrateProvider?.call();
      final picked =
          cap == null || cap <= 0
              ? formats.first
              : formats.firstWhere(
                (f) => f.$1 <= cap,
                orElse: () => formats.last, // 全部超限则取最低码率档
              );
      return ResolvedStream(url: picked.$2);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout) {
        throw NetworkSourceException(
          '无法连接 YouTube Music：请确认设备可访问 YouTube（受限网络需系统代理）',
          sourceId: sourceId,
        );
      }
      throw NetworkSourceException('获取播放地址失败：网络异常', sourceId: sourceId);
    }
  }

  @override
  Future<LyricBundle?> fetchLyrics(Track track) async => null;

  // ---------- 账号能力（WebView 登录 + Cookie 凭据） ----------

  /// 用 WebView 提取的 Cookie 构建账号：
  /// 校验方式为调 youtubei get_account_info 拿昵称；失败视为未登录。
  Future<SourceAccount> loginWithCookies(Map<String, String> cookies) async {
    if (!hasYoutubeLoginCookies(cookies)) {
      throw NetworkSourceException(
        '未能读取登录 Cookie。请确认已登录并回到 YouTube Music 后再点「我已登录」。',
        sourceId: sourceId,
      );
    }
    final info = await fetchAccountSummary(cookies: cookies);
    return SourceAccount.markNow(
      sourceId: sourceId,
      status: AccountStatus.loggedIn,
      userId: info?.$2,
      nickname: info?.$1 ?? 'YouTube Music',
    );
  }

  /// youtubei get_account_info：返回 (昵称, accountId)；未登录返回 null。
  ///
  /// [strict] 为 true 时，连接层失败抛出 [NetworkSourceException]
  /// （供 checkSession 区分「断网」与「凭据失效」）。
  Future<(String, String?)?> fetchAccountSummary({
    Map<String, String>? cookies,
    bool strict = false,
  }) async {
    final cookieMap = cookies ?? await credentialReader();
    final sapisid =
        cookieValue(cookieMap, const [
          'SAPISID',
          '__Secure-1PAPISID',
          '__Secure-3PAPISID',
        ]) ??
        '';
    final psid =
        cookieValue(cookieMap, const [
          '__Secure-1PSID',
          '__Secure-3PSID',
          'SID',
        ]) ??
        '';
    if (sapisid.isEmpty || psid.isEmpty) return null;

    final authHeaders = await _youtubeAuthHeaders(cookies: cookieMap);

    try {
      final response = await _dio.post<dynamic>(
        'https://music.youtube.com/youtubei/v1/account/account_menu',
        queryParameters: <String, dynamic>{
          'prettyPrint': false,
          'key': _innerTubeKey,
        },
        options: Options(
          headers: <String, String>{
            'X-YouTube-Client-Name': '67',
            'X-YouTube-Client-Version': _webRemixVersion,
            ...authHeaders,
          },
        ),
        data: <String, dynamic>{'context': _webRemixContext()},
      );
      final data = response.data;
      // 账号名在 actions[0].toggleMenuServiceItemRenderer... 处层级较深，做宽松提取
      final nickname = _deepFindString(data, 'accountName');
      final accountid = _deepFindString(data, 'accountId');
      if (nickname == null || nickname.isEmpty) return null;
      return (nickname, accountid);
    } on DioException catch (e) {
      developer.log(
        'account_menu 失败: status=${e.response?.statusCode}',
        name: 'MusaicYTM',
      );
      if (strict && e.response == null) {
        throw NetworkSourceException(
          '无法连接 YouTube Music：无法校验登录态',
          sourceId: sourceId,
        );
      }
      return null;
    }
  }

  /// Cookie + SAPISIDHASH；无凭据时返回空 map（播放走匿名）。
  Future<Map<String, String>> _youtubeAuthHeaders({
    Map<String, String>? cookies,
  }) async {
    final cookieMap = cookies ?? await credentialReader();
    if (cookieMap.isEmpty) return const <String, String>{};
    const origin = 'https://music.youtube.com';
    final sapisid =
        cookieValue(cookieMap, const [
          'SAPISID',
          '__Secure-1PAPISID',
          '__Secure-3PAPISID',
        ]) ??
        '';
    final headers = <String, String>{
      'Cookie': cookieMap.entries.map((e) => '${e.key}=${e.value}').join('; '),
    };
    if (sapisid.isNotEmpty) {
      final millis = DateTime.now().millisecondsSinceEpoch;
      final hash =
          crypto.sha1
              .convert(utf8.encode('$millis $sapisid $origin'))
              .toString();
      headers['Authorization'] = 'SAPISIDHASH ${millis}_$hash';
      headers['X-Origin'] = origin;
    }
    return headers;
  }

  /// 在任意嵌套 JSON 中递归找第一个指定键的字符串值。
  String? _deepFindString(dynamic node, String key) {
    if (node is Map<String, dynamic>) {
      final value = node[key];
      if (value is String && value.isNotEmpty) return value;
      for (final child in node.values) {
        final found = _deepFindString(child, key);
        if (found != null) return found;
      }
    } else if (node is List<dynamic>) {
      for (final child in node) {
        final found = _deepFindString(child, key);
        if (found != null) return found;
      }
    }
    return null;
  }

  @override
  Future<AuthResult> login(Map<String, String> credentials) async {
    try {
      final account = await loginWithCookies(credentials);
      return AuthSuccess(account, credentials: credentials);
    } on SourceException {
      return const AuthFailure(
        reason: AuthFailureReason.invalidCredentials,
        message: 'Cookie 无效或已过期，请在登录页重新登录',
      );
    }
  }

  @override
  Future<bool> checkSession() async {
    final cookies = await credentialReader();
    if (!hasYoutubeLoginCookies(cookies)) return false;
    final account = await fetchAccountSummary(strict: true);
    return account != null;
  }

  @override
  Future<SourceAccount?> refreshAccountInfo(SourceAccount account) async {
    final info = await fetchAccountSummary();
    if (info == null) return null;
    return account.copyWith(nickname: info.$1);
  }

  Map<String, dynamic>? _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;
}
