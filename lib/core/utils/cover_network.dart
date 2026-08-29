/// 封面 / 头像网络请求头。
///
/// [Image.network] / [CachedNetworkImage] 默认 UA 是 `Dart/x (dart:io)`，
/// QQ（y.gtimg.cn）和网易云（126.net）CDN 会直接 403，界面只剩占位图。
library;

/// 渠道 CDN 可接受的浏览器 UA（不伪装成过时桌面 Chrome）。
const kCoverUserAgent =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';

/// 按封面 URL 主机补 Referer / UA。未知主机仍带 UA，避免 Dart 默认头被拒。
Map<String, String> coverHttpHeaders(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  final headers = <String, String>{'User-Agent': kCoverUserAgent};
  if (_isQqCoverHost(host)) {
    headers['Referer'] = 'https://y.qq.com/';
  } else if (_isNeteaseCoverHost(host)) {
    headers['Referer'] = 'https://music.163.com/';
  } else if (_isKugouCoverHost(host)) {
    headers['Referer'] = 'https://www.kugou.com/';
  }
  return headers;
}

/// 归一化封面 URL，提升磁盘缓存命中率（功耗计划 PW-11）。
///
/// 同一专辑封面常以不同尺寸参数散布在各接口（网易云 `?param=wYh`、
/// QQ 路径内 `R{w}x{h}`），尺寸变体各异会导致缓存 miss 重复下载。
/// 网易云归一到 `?param=512y512`（动态缩放，任意尺寸可用）；
/// QQ 归一到 `R500x500M`（CDN 只有固定尺寸档，512 变体 404 实测）：
/// 各组件（列表 / 迷你条 / 播放页 / 系统媒体）共享同一份下载与解码缓存。
String normalizeCoverUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  final host = uri.host.toLowerCase();
  if (_isNeteaseCoverHost(host)) {
    final base = url.split('?').first;
    return '$base?param=512y512';
  }
  if (_isQqCoverHost(host)) {
    return url.replaceFirstMapped(RegExp(r'R\d+x\d+M'), (match) => 'R500x500M');
  }
  return url;
}

bool _isQqCoverHost(String host) =>
    host.contains('gtimg.cn') ||
    host.contains('qq.com') ||
    host.contains('qpic.cn');

bool _isNeteaseCoverHost(String host) =>
    host.contains('126.net') ||
    host.contains('163.com') ||
    host.contains('netease.com');

bool _isKugouCoverHost(String host) =>
    host.contains('kugou') || host.contains('kgimg');
