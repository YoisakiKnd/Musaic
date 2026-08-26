/// 渠道返回 URL 的统一清理工具。
library;

extension UrlSanitizeX on String? {
  /// 把 http:// 封面/资源地址升级为 https（Android 默认禁止明文，
  /// 部分渠道返回 http 图链会导致封面全部加载失败）。
  String? toHttps() {
    final value = this;
    if (value == null || value.isEmpty) return value;
    if (value.startsWith('http://')) {
      return value.replaceFirst('http://', 'https://');
    }
    return value;
  }
}
