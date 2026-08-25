import 'package:dio/dio.dart';

/// 凭据读取器类型（与渠道解耦）。
typedef HeaderCredentialReader = Future<Map<String, String>> Function();

/// 会话过期回调（由 AccountNotifier 订阅后标记「已过期」）。
typedef SessionExpiredCallback = void Function();

/// 渠道认证拦截器（Master Plan §5.1 / §6）。
///
/// - 请求前注入凭据头（如 `Cookie: MUSIC_U=…`）。
/// - 捕获 401 / 301 或业务码 301，被动上报会话过期。
/// - 日志与异常信息永不包含凭据值。
class SourceAuthInterceptor extends Interceptor {
  SourceAuthInterceptor({
    required this.sourceId,
    required this.readCredentials,
    required this.onSessionExpired,
    this.headerName = 'Cookie',
    this.expiredBodyCodes = const <int>{301},
  });

  final String sourceId;
  final HeaderCredentialReader readCredentials;
  final SessionExpiredCallback onSessionExpired;

  /// 注入的头名；网易云用 Cookie。
  final String headerName;

  /// 响应体中代表「未登录/失效」的业务 code 集合。
  final Set<int> expiredBodyCodes;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      final credentials = await readCredentials();
      if (credentials.isNotEmpty) {
        final cookie = credentials.entries
            .map((e) => '${e.key}=${e.value}')
            .join('; ');
        options.headers[headerName] = cookie;
      }
    } catch (_) {
      // 凭据读取失败时按匿名请求继续，不打断播放主链路。
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    if (_isSessionExpired(response)) {
      onSessionExpired();
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final status = err.response?.statusCode;
    if (status == 401 || status == 302 && _isAuthRedirect(err.response)) {
      onSessionExpired();
    }
    handler.next(err);
  }

  bool _isSessionExpired(Response<dynamic> response) {
    final status = response.statusCode;
    if (status == 401 || status == 301) return true;
    final data = response.data;
    if (data is Map && data['code'] is int) {
      final bodyCode = data['code'] as int;
      if (expiredBodyCodes.contains(bodyCode)) return true;
    }
    return false;
  }

  bool _isAuthRedirect(Response<dynamic>? response) =>
      response?.headers.value('location')?.contains('passport') ?? false;
}
