import 'dart:convert';

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
    this.injectCredentials = true,
    this.expiredBodyCodes = const <int>{301},
  });

  final String sourceId;
  final HeaderCredentialReader readCredentials;
  final SessionExpiredCallback onSessionExpired;

  /// 注入的头名；网易云用 Cookie。
  final String headerName;

  /// 是否在请求前注入凭据头。
  /// 关闭时仅做被动过期捕获（如 YTM 自行管理 Authorization 头的渠道）。
  final bool injectCredentials;

  /// 响应体中代表「未登录/失效」的业务 code 集合。
  final Set<int> expiredBodyCodes;

  /// 登录请求设此 extra，避免过期后残留凭据覆盖游客 Cookie / 污染扫码接口。
  static const String skipAuthExtraKey = 'musaic.skipAuth';

  static Options skipAuth([Options? options]) {
    final extra = <String, dynamic>{...?options?.extra, skipAuthExtraKey: true};
    return (options ?? Options()).copyWith(extra: extra);
  }

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (injectCredentials && options.extra[skipAuthExtraKey] != true) {
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
    final code = _extractBodyCode(response.data);
    return code != null && expiredBodyCodes.contains(code);
  }

  /// 从响应体中提取业务 code。
  ///
  /// 各渠道普遍使用 `ResponseType.plain`（网易云 / QQ / 酷狗），
  /// 此时 [Response.data] 恒为 String，旧实现直接 `data is Map` 判断
  /// 导致业务码过期检测**完全失效**（P1 回归守护）。
  /// 这里同时兼容已解析的 Map 与原始 JSON 字符串。
  static int? _extractBodyCode(Object? data) {
    Object? decoded = data;
    if (decoded is String) {
      final text = decoded.trim();
      if (text.isEmpty) return null;
      // 仅尝试解析 JSON 对象/数组；HTML 错误页等直接放弃。
      if (!text.startsWith('{') && !text.startsWith('[')) return null;
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        return null;
      }
    }
    if (decoded is Map) {
      final raw = decoded['code'];
      if (raw is int) return raw;
      if (raw is String) return int.tryParse(raw);
    }
    return null;
  }

  bool _isAuthRedirect(Response<dynamic>? response) =>
      response?.headers.value('location')?.contains('passport') ?? false;
}
