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

extension _ConnectivityResults on List<ConnectivityResult> {
  bool get isOnWifi =>
      contains(ConnectivityResult.wifi) ||
      contains(ConnectivityResult.ethernet);
}
