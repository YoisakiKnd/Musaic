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
import '../../core/lyrics/lyric_bundle.dart';

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
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
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
  String get webLoginActionLabel => '我已登录';

  @override
  String get webLoginHint =>
      '在上方页面登录 Google 账号后，点击右上角「我已登录」。'
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
  static const String _songsFilterParams =
      'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D';

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
      final response = await _dio.post<dynamic>(
        'https://music.youtube.com/youtubei/v1/search',
        queryParameters: const <String, dynamic>{'prettyPrint': false},
        options: Options(
          headers: <String, String>{
            'X-YouTube-Client-Name': '67',
            'X-YouTube-Client-Version': _webRemixVersion,
          },
        ),
        data: <String, dynamic>{
          'context': _webRemixContext(),
          'query': keyword,
          'params': _songsFilterParams,
        },
      );
      final results = _extractSongs(_asMap(response.data));
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
      final response = await _dio.post<dynamic>(
        'https://music.youtube.com/youtubei/v1/player',
        queryParameters: const <String, dynamic>{'prettyPrint': false},
        options: Options(
          headers: <String, String>{
            'User-Agent':
                'com.google.android.apps.youtube.music/$_androidMusicVersion (Linux; U; Android 11) gzip',
            'X-YouTube-Client-Name': '21',
            'X-YouTube-Client-Version': _androidMusicVersion,
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
            _asMap(root?['playabilityStatus'])?['reason'] as String? ??
                '不可播放';
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
      final picked = cap == null || cap <= 0
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
      throw NetworkSourceException('获取播放地址失败：网络异常',
          sourceId: sourceId);
    }
  }

  @override
  Future<LyricBundle?> fetchLyrics(Track track) async => null;

  // ---------- 账号能力（WebView 登录 + Cookie 凭据） ----------

  /// 用 WebView 提取的 Cookie 构建账号：
  /// 校验方式为调 youtubei get_account_info 拿昵称；失败视为未登录。
  Future<SourceAccount> loginWithCookies(
    Map<String, String> cookies,
  ) async {
    final info = await fetchAccountSummary(cookies: cookies);
    if (info == null) {
      throw NetworkSourceException('未检测到有效登录态', sourceId: sourceId);
    }
    return SourceAccount.markNow(
      sourceId: sourceId,
      status: AccountStatus.loggedIn,
      userId: info.$2,
      nickname: info.$1,
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
    final sapisid = cookieMap['SAPISID'] ??
        cookieMap['__Secure-1PAPISID'] ??
        cookieMap['__Secure-3PAPISID'] ??
        '';
    final psid = cookieMap['__Secure-1PSID'] ??
        cookieMap['__Secure-3PSID'] ??
        cookieMap['SID'] ??
        '';
    if (sapisid.isEmpty || psid.isEmpty) return null;

    const origin = 'https://music.youtube.com';
    final millis = DateTime.now().millisecondsSinceEpoch;
    // SAPISIDHASH 授权头
    final hashInput = '$millis $sapisid $origin';
    final hash = crypto.sha1
        .convert(const AsciiEncoder().convert(hashInput))
        .toString();
    final authorization = 'SAPISIDHASH ${millis}_$hash';

    try {
      final response = await _dio.post<dynamic>(
        '/youtubei/v1/account/account_menu',
        queryParameters: <String, dynamic>{'prettyPrint': false},
        options: Options(
          headers: <String, String>{
            'Authorization': authorization,
            'X-Origin': origin,
            'X-Youtube-Client-Name': '52',
            'X-Youtube-Client-Version': _webRemixVersion,
            'Cookie': cookieMap.entries
                .map((e) => '${e.key}=${e.value}')
                .join('; '),
          },
        ),
        data: <String, dynamic>{
          'context': <String, dynamic>{
            'client': <String, dynamic>{
              'clientName': 'WEB_REMIX',
              'clientVersion': _webRemixVersion,
              'hl': 'zh-CN',
              'gl': 'CN',
            },
          },
        },
      );
      final data = response.data;
      // 账号名在 actions[0].toggleMenuServiceItemRenderer... 处层级较深，做宽松提取
      final nickname = _deepFindString(data, 'accountName') ??
          _deepFindString(data, 'text');
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
    final hasAuthCookie = (cookies['SAPISID'] ??
            cookies['__Secure-1PAPISID'] ??
            cookies['__Secure-3PAPISID'] ??
            '')
        .isNotEmpty;
    if (!hasAuthCookie) return false;
    // strict：连接层失败抛出，上层保留乐观登录态；
    // 仅「拿到响应但无有效账号信息」判定为过期。
    return await fetchAccountSummary(strict: true) != null;
  }

  @override
  Future<SourceAccount?> refreshAccountInfo(SourceAccount account) async {
    final info = await fetchAccountSummary();
    if (info == null) return null;
    return account.copyWith(nickname: info.$1);
  }

  // ---------- 解析 ----------

  List<Track> _extractSongs(Map<String, dynamic>? root) {
    final results = <Track>[];
    final contents = _path(root, [
      'contents',
      'tabbedSearchResultsRenderer',
      'tabs',
    ]) as List<dynamic>?;
    final tabContent = _asMap(_asList(contents)?.firstOrNull?['tabRenderer'])
        ?['content'];
    final sections =
        _asMap(tabContent)?['sectionListRenderer']?['contents']
            as List<dynamic>?;
    for (final section in sections ?? const <dynamic>[]) {
      final shelf = _asMap(_asMap(section)?['musicShelfRenderer']);
      final items = shelf?['contents'] as List<dynamic>?;
      for (final item in items ?? const <dynamic>[]) {
        final track = _parseListItem(_asMap(item));
        if (track != null) results.add(track);
      }
    }
    return results;
  }

  Track? _parseListItem(Map<String, dynamic>? item) {
    if (item == null) return null;
    final videoId = _path(item, [
      'playlistItemData',
      'videoId',
    ]) as String?;
    if (videoId == null || videoId.isEmpty) return null;

    final flexColumns =
        item['flexColumns'] as List<dynamic>? ?? const <dynamic>[];
    String title = '';
    final artists = <String>[];
    String? album;
    Duration? duration;

    for (var i = 0; i < flexColumns.length; i++) {
      final runs = _path(_asMap(flexColumns[i]), [
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
      ]) as List<dynamic>?;
      if (runs == null || runs.isEmpty) continue;
      if (i == 0) {
        title = _asMap(runs.first)?['text'] as String? ?? '';
        continue;
      }
      for (final rawRun in runs) {
        final run = _asMap(rawRun);
        final text = run?['text'] as String? ?? '';
        final watch =
            _path(run, ['navigationEndpoint', 'watchEndpoint']);
        final pageType = _path(run, [
          'navigationEndpoint',
          'watchEndpoint',
          'watchEndpointMusicSupportedConfigs',
          'watchEndpointMusicConfig',
          'musicVideoType',
        ]);
        if (watch != null) {
          // 专辑或歌曲跳转：ATM_VIDEO / album 页面类型视为专辑名
          if (pageType == 'MUSIC_PAGE_TYPE_ALBUM') album = text;
        } else if (RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$').hasMatch(text)) {
          duration = _parseDuration(text);
        } else if (text.trim().isNotEmpty) {
          artists.add(text.trim());
        }
      }
    }
    if (title.isEmpty) return null;

    final thumbs = _path(item, [
      'thumbnail',
      'musicThumbnailRenderer',
      'thumbnail',
      'thumbnails',
    ]) as List<dynamic>?;
    String? coverUrl;
    if (thumbs != null && thumbs.isNotEmpty) {
      coverUrl = _asMap(thumbs.last)?['url'] as String?;
    }

    return Track(
      id: videoId,
      sourceId: sourceId,
      title: title,
      artist: artists.isEmpty ? 'Unknown Artist' : artists.join('/'),
      album: album,
      duration: duration,
      coverUrl: coverUrl,
      sourceData: <String, dynamic>{'videoId': videoId},
    );
  }

  Duration? _parseDuration(String text) {
    final parts = text.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]);
      final s = int.tryParse(parts[1]);
      if (m != null && s != null) return Duration(minutes: m, seconds: s);
    } else if (parts.length == 3) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final s = int.tryParse(parts[2]);
      if (h != null && m != null && s != null) {
        return Duration(hours: h, minutes: m, seconds: s);
      }
    }
    return null;
  }

  dynamic _path(Map<String, dynamic>? map, List<String> keys) {
    dynamic current = map;
    for (final key in keys) {
      if (current is! Map) return null;
      current = current[key];
    }
    return current;
  }

  List<dynamic>? _asList(dynamic value) =>
      value is List ? value : null;

  Map<String, dynamic>? _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
