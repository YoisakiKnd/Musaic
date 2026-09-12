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

/// 需要持久化的 YouTube / YTM 会话 Cookie 白名单。
///
/// 采集阶段必须读取 `accounts.google.com` 才能拿到 SAPISIDHASH 所需的
/// 凭据，但**绝不能把该域下的全部 Cookie 落盘**：那里混有 Google 账号
/// 的其它会话 Cookie（`LSID`/`HSID`/`SSID`/`NID` 等），超出本应用所需的
/// 最小权限。这里只放行播放与鉴权真正用到的键（P1 安全回归）。
const List<String> kYoutubeSessionCookieNames = <String>[
  'SAPISID',
  '__Secure-1PAPISID',
  '__Secure-3PAPISID',
  'SID',
  'HSID',
  'SSID',
  'APISID',
  '__Secure-1PSID',
  '__Secure-3PSID',
  '__Secure-1PSIDTS',
  '__Secure-3PSIDTS',
  'LOGIN_INFO',
  'VISITOR_INFO1_LIVE',
  'PREF',
  'CONSENT',
  'SOCS',
];

/// 按白名单裁剪采集结果，只保留会话所需的 Cookie 键。
///
/// 键名匹配不区分大小写（各平台对 Cookie 名大小写处理不一致）。
Map<String, String> filterYoutubeSessionCookies(Map<String, String> cookies) {
  final allowed = <String>{
    for (final name in kYoutubeSessionCookieNames) name.toLowerCase(),
  };
  return <String, String>{
    for (final entry in cookies.entries)
      if (allowed.contains(entry.key.toLowerCase())) entry.key: entry.value,
  };
}
