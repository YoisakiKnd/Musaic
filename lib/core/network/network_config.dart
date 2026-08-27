import 'package:dio/dio.dart';

/// 全局网络超时配置（设置页「请求超时」驱动，单位秒）。
///
/// 各渠道 Dio 构建时用它作初值；运行时通过 [_TimeoutInterceptor]
/// 每次请求回读，实现「改设置即时生效」而无需重建渠道实例。
class NetworkConfig {
  NetworkConfig._();

  static final NetworkConfig instance = NetworkConfig._();

  static const int defaultSeconds = 8;
  static const int minSeconds = 4;
  static const int maxSeconds = 20;

  int _seconds = defaultSeconds;

  int get seconds => _seconds;

  Duration get connect => Duration(seconds: _seconds);

  /// receive 给到 1.25 倍，弱网下载比握手更耗时。
  Duration get receive =>
      Duration(milliseconds: (_seconds * 1000 * 1.25).round());

  void set(int value) {
    _seconds = value.clamp(minSeconds, maxSeconds);
  }

  /// 由持久化设置恢复（启动时组合根调用）。
  void restore(int? value) {
    if (value != null) set(value);
  }
}

/// 每次请求按 [NetworkConfig] 现值覆写超时。
class TimeoutInterceptor extends Interceptor {
  TimeoutInterceptor({NetworkConfig? config})
      : _config = config ?? NetworkConfig.instance;

  final NetworkConfig _config;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.connectTimeout = _config.connect;
    options.receiveTimeout = _config.receive;
    handler.next(options);
  }
}
