import '../../core/logging/app_logger.dart';

/// 加载/写入失败的界面文案（计划 3.4）。
///
/// ## 为什么需要它
///
/// 此前多处直接 `Text('加载失败：$e')`：`$e` 是底层异常原文，可能是
/// `PathNotFoundException: Cannot open file, path = '/data/.../x.json'`
/// 这类内容——对用户既不可读，又泄露本机路径。用户真正需要的是
/// 「失败了、可以重试」，细节应进日志而不是界面。
///
/// ## 为什么要做去重
///
/// 这些文案产生在 `AsyncValue.when(error: ...)` 的 build 回调里：
/// 错误态下每次重建都会再走一遍。若每次都写日志，[AppLog] 的 500 条
/// 环形缓冲会被同一条错误刷满，把「导出诊断日志」这个功能的价值冲掉。
/// 因此同一个错误对象只记录一次。
///
/// [prefix] 用「导出失败」/「加入失败」这类动作词，比笼统的「操作失败」有用。
String loadFailureText(
  Object error, {
  required String tag,
  String prefix = '加载失败',
}) {
  _logOnce(error, tag: tag, prefix: prefix);
  return '$prefix，请重试';
}

/// 同一错误对象只记录一次。
///
/// 用 [Expando]（弱引用，不阻止 GC）以错误对象本身为键；
/// 若 [error] 不是可作 Expando 键的对象（如 String / num），
/// 退化为每次都记——那种情况本就罕见，且不会持续刷屏。
final Expando<bool> _logged = Expando<bool>('musaic_logged_error');

void _logOnce(Object error, {required String tag, required String prefix}) {
  try {
    if (_logged[error] ?? false) return;
    _logged[error] = true;
  } catch (_) {
    // 非 Expando 可用的键：不阻断，直接记日志。
  }
  AppLog.error('$prefix：$error', tag: tag);
}
