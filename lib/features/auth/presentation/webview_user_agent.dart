/// 把 Android System WebView 的 UA 收成接近 Chrome 的形态。
///
/// Google 登录会拦截：
/// - 内嵌 WebView 自带的 `; wv)` 标记
/// - 与真实引擎不符的过时桌面 Chrome UA（例如 Windows Chrome/124）
///
/// 保留 WebView 真实 Chrome 大版本，只去掉 wv / Version/4.0。
String chromeLikeUserAgent(String webViewUserAgent) {
  var ua = webViewUserAgent.trim();
  if (ua.isEmpty) return ua;
  ua = ua.replaceAll('; wv)', ')');
  ua = ua.replaceAll(RegExp(r'; wv\b'), '');
  ua = ua.replaceFirst(RegExp(r'\sVersion/[\d.]+\s'), ' ');
  return ua.replaceAll(RegExp(r'\s+'), ' ').trim();
}
