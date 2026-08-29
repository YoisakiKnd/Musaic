import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/features/auth/presentation/webview_user_agent.dart';

void main() {
  test('去掉 Android WebView 的 wv 标记，保留真实 Chrome 版本', () {
    const raw =
        'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A; wv) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
        'Chrome/140.0.7339.51 Mobile Safari/537.36';
    final ua = chromeLikeUserAgent(raw);
    expect(ua, isNot(contains('wv')));
    expect(ua, isNot(contains('Version/4.0')));
    expect(ua, contains('Chrome/140.0.7339.51'));
    expect(ua, contains('Android 14'));
  });

  test('空字符串保持为空', () {
    expect(chromeLikeUserAgent(''), isEmpty);
  });
}
