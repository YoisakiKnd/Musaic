import 'dart:io' show HttpClient;

import 'package:dio/dio.dart';
import 'package:dio/io.dart' show IOHttpClientAdapter;

import 'network_config.dart';
import 'source_auth_interceptor.dart';

/// 连接空闲超时。
///
/// Dio 默认仅 **3 秒**（见 `io_adapter.dart`）——用户点歌时连接早已过期，
/// 必须重新做 DNS + TLS 握手，这是「点歌到出声」延迟的主要来源之一。
///
/// 延长到 90 秒：覆盖用户浏览列表、犹豫、再点歌的典型间隔，
/// 让第二次请求复用已有连接。同时不会长期占用服务端连接
/// （空闲连接由 HttpClient 自动回收）。
const Duration kHttpIdleTimeout = Duration(seconds: 90);

/// 每个 host 的最大并发连接数。
///
/// 默认不限制；QQ 封面补全曾有并发闸（4 路），这里给个上限避免
/// 极端情况下打爆单个 host。
const int kHttpMaxConnectionsPerHost = 8;

/// 渠道 Dio 装配（Master Plan §5.1）。
///
/// 四个渠道原先各自复制了一份 `_buildDio`（超时、UA/Referer、
/// 认证拦截器、动态超时拦截器），字段漂移风险高。此处统一装配，
/// 渠道只需声明 baseUrl / 默认头 / 是否注入凭据。
///
/// 约定：
/// - `validateStatus` 只接受 2xx/3xx；4xx 交给 [DioException] 处理，
///   避免把「参数错误 / 鉴权失败」当成成功响应解析成空结果。
/// - 始终附加 [TimeoutInterceptor]，使设置页的「请求超时」即时生效。
Dio buildSourceDio({
  required String sourceId,
  String? baseUrl,
  Map<String, String>? headers,
  HeaderCredentialReader? readCredentials,
  void Function()? onSessionExpired,
  bool injectCredentials = true,
  Set<int> expiredBodyCodes = const <int>{301},
  List<Interceptor> interceptors = const <Interceptor>[],
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl ?? '',
      connectTimeout: NetworkConfig.instance.connect,
      receiveTimeout: NetworkConfig.instance.receive,
      sendTimeout: NetworkConfig.instance.connect,
      headers: headers ?? const <String, String>{},
      validateStatus: (int? code) => code != null && code >= 200 && code < 400,
    ),
  );

  // 连接复用：显著降低重复点歌/切歌时的握手开销。
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      client.idleTimeout = kHttpIdleTimeout;
      client.maxConnectionsPerHost = kHttpMaxConnectionsPerHost;
      return client;
    },
  );

  if (readCredentials != null || onSessionExpired != null) {
    dio.interceptors.add(
      SourceAuthInterceptor(
        sourceId: sourceId,
        readCredentials:
            readCredentials ?? () async => const <String, String>{},
        onSessionExpired: onSessionExpired ?? () {},
        injectCredentials: injectCredentials,
        expiredBodyCodes: expiredBodyCodes,
      ),
    );
  }
  dio.interceptors.add(TimeoutInterceptor());
  dio.interceptors.addAll(interceptors);
  return dio;
}
