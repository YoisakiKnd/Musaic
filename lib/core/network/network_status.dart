import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 当前是否处于非计费高带宽链路（Wi-Fi / 以太网）。
///
/// 判定失败时视为 Wi-Fi（fail-open：不做蜂窝降档），
/// 供「蜂窝自动降质」（功耗计划 PW-09）在播放解析前读取。
final connectivityIsWifiProvider = StreamProvider<bool>((ref) async* {
  final connectivity = Connectivity();
  try {
    yield (await connectivity.checkConnectivity()).isOnWifi;
  } catch (_) {
    yield true;
    return;
  }
  await for (final results in connectivity.onConnectivityChanged) {
    yield results.isOnWifi;
  }
});

/// 当前是否有任意网络连接（Wi-Fi / 蜂窝 / 以太网 / VPN …）。
///
/// 播放器据此在「断网导致播放失败」后、网络恢复时自动续播。
/// 判定失败时视为在线（fail-open：不阻止任何操作）。
final networkOnlineProvider = StreamProvider<bool>((ref) async* {
  final connectivity = Connectivity();
  try {
    yield (await connectivity.checkConnectivity()).isOnline;
  } catch (_) {
    yield true;
    return;
  }
  await for (final results in connectivity.onConnectivityChanged) {
    yield results.isOnline;
  }
});

extension _ConnectivityResults on List<ConnectivityResult> {
  bool get isOnline => any((r) => r != ConnectivityResult.none);

  bool get isOnWifi =>
      contains(ConnectivityResult.wifi) ||
      contains(ConnectivityResult.ethernet);
}
