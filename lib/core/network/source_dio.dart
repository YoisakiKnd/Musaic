import 'package:dio/dio.dart';

import 'network_config.dart';
import 'source_auth_interceptor.dart';

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
