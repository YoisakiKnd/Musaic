/// 从 WebView Cookie 列表 / document.cookie 头里合并键值。
library;

void mergeCookiePair(
  Map<String, String> into,
  String name,
  dynamic value, {
  bool overwrite = false,
}) {
  final key = name.trim();
  if (key.isEmpty) return;
  if (value == null) return;
  final text = value is String ? value : value.toString();
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed == 'null') return;
  if (!overwrite && into.containsKey(key)) return;
  into[key] = trimmed;
}

/// 解析 `a=1; b=2` 形式（document.cookie 或 Cookie 请求头）。
void mergeCookieHeader(Map<String, String> into, String header) {
  var raw = header.trim();
  if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
    raw = raw.substring(1, raw.length - 1);
  }
  if (raw.isEmpty) return;
  for (final part in raw.split(';')) {
    final index = part.indexOf('=');
    if (index <= 0) continue;
    mergeCookiePair(into, part.substring(0, index), part.substring(index + 1));
  }
}

String? cookieValue(Map<String, String> cookies, List<String> names) {
  for (final name in names) {
    final direct = cookies[name];
    if (direct != null && direct.isNotEmpty) return direct;
  }
  final lower = <String, String>{
    for (final entry in cookies.entries) entry.key.toLowerCase(): entry.value,
  };
  for (final name in names) {
    final value = lower[name.toLowerCase()];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

bool hasYoutubeLoginCookies(Map<String, String> cookies) {
  final sapisid =
      cookieValue(cookies, const [
        'SAPISID',
        '__Secure-1PAPISID',
        '__Secure-3PAPISID',
      ]) ??
      '';
  final psid =
      cookieValue(cookies, const ['__Secure-1PSID', '__Secure-3PSID', 'SID']) ??
      '';
  return sapisid.isNotEmpty && psid.isNotEmpty;
}

/// 判断 Cookie 所属域名是否属于登录能力声明的允许来源。
bool isCookieHostAllowed(String host, Iterable<Uri> origins) {
  final normalizedHost = host.toLowerCase().trim().replaceFirst(
    RegExp(r'^\\.'),
    '',
  );
  if (normalizedHost.isEmpty) return false;
  for (final origin in origins) {
    final allowedHost = origin.host.toLowerCase().trim().replaceFirst(
      RegExp(r'^\\.'),
      '',
    );
    if (allowedHost.isEmpty) continue;
    if (normalizedHost == allowedHost ||
        normalizedHost.endsWith('.$allowedHost')) {
      return true;
    }
  }
  return false;
}
