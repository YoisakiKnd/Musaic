/// 统一日志入口（迭代计划 H4 / 改进计划 I1-logs）。
///
/// 背景：项目此前直接用 `debugPrint` / `developer.log`，存在两类问题：
/// 1. **凭据泄漏**：如网易云 `createQrLogin` 曾把整个响应体写进日志，
///    其中含登录 `unikey`；URL query 里的 token 也可能被整条打印；
/// 2. **release 静默**：`debugPrint` 在生产构建被裁剪，真机排障没有线索。
///
/// 本模块提供：
/// - 统一的 [AppLog] 调用面（级别 + 标签）；
/// - **写入前强制脱敏**：URL query、Cookie/Authorization 头、
///   以及常见凭据键（token / unikey / MUSIC_U / musickey / SAPISID…）；
/// - 内存环形缓冲，供「设置 → 导出诊断」读取（不落盘、不联网）。
library;

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

enum AppLogLevel { debug, info, warning, error }

/// 需要整体遮蔽的敏感键（匹配不区分大小写）。
const List<String> _sensitiveKeys = <String>[
  'token',
  'access_token',
  'refresh_token',
  'unikey',
  'music_u',
  'musickey',
  'musicid',
  'cookie',
  'set-cookie',
  'authorization',
  'sapisid',
  'sapisidhash',
  'psid',
  'sid',
  'password',
  'passwd',
  'secret',
  'signature',
  'vkey',
  'purl',
  'userid',
  'uin',
  'credential',
  'openid',
  'session_key',
];

const String _redacted = '***';

/// 敏感键的匹配分支（`token|unikey|...`，已做正则转义）。
final String _keysAlternation = _sensitiveKeys.map(RegExp.escape).join('|');

/// 正则：`key=value` / `key: value` / `"key":"value"` / `key%3Dvalue`
/// 形态的敏感键值对，命中即把 value 替换为 `***`。
///
/// 用 raw string 分段拼接以避免转义噪音；`\s` 等保持正则语义。
final RegExp _sensitivePair = RegExp(
  r'([?&;,\s"{]|^)'
  '($_keysAlternation)'
  // 分隔符允许被引号包裹的 JSON 形态：`"MUSIC_U":"v"` / `"token"="v"`
  r'("?\s*(?:%3D|%3d|=|:)\s*)'
  r'("?)([^&;,\s")\]}]*)',
  caseSensitive: false,
);

/// 正则：URL query 段 `?k=v&k2=v2`。渠道常把凭据塞进 query，
/// 白名单不可能穷尽，因此 query 值一律遮蔽。
final RegExp _anyQueryPair = RegExp(r'([?&])([^=&\s]+)=([^&\s]+)');

/// 正则：`Bearer xxx` / `Basic xxx`。
final RegExp _authScheme = RegExp(
  r'\b(Bearer|Basic)\s+[A-Za-z0-9\-._~+/=]+',
  caseSensitive: false,
);

/// 对任意日志文本做脱敏。
///
/// 这是**唯一**的清洗入口；[AppLog] 的所有方法都会先经过它。
/// 宁可过度遮蔽，也不放过凭据。
String redactForLog(String input) {
  if (input.isEmpty) return input;
  var out = input;

  // 1) Bearer / Basic 令牌
  out = out.replaceAllMapped(_authScheme, (m) => '${m.group(1)} $_redacted');

  // 2) 敏感键值对（JSON / query / header 三种形态）
  out = out.replaceAllMapped(
    _sensitivePair,
    (m) => '${m.group(1) ?? ''}${m.group(2) ?? ''}=$_redacted',
  );

  // 3) 兜底：URL query 的值整体遮蔽
  out = out.replaceAllMapped(
    _anyQueryPair,
    (m) => '${m.group(1) ?? '?'}${m.group(2) ?? ''}=$_redacted',
  );

  return out;
}

/// 一条日志记录（供诊断导出）。
@immutable
class AppLogRecord {
  const AppLogRecord({
    required this.level,
    required this.tag,
    required this.message,
    required this.timestamp,
  });

  final AppLogLevel level;
  final String tag;
  final String message;
  final DateTime timestamp;

  @override
  String toString() =>
      '${timestamp.toIso8601String()} [${level.name.toUpperCase()}] '
      '($tag) $message';
}

/// 应用日志门面。
///
/// 使用约定：
/// - 禁止再直接调用 `debugPrint` / `developer.log`（除 [AppLog] 内部）；
/// - 需要打印响应体时，只打印**结构**（键名、条数），不要打印原始值。
abstract final class AppLog {
  /// 环形缓冲容量：仅保留最近若干条，避免长会话内存增长。
  static const int ringCapacity = 500;

  static final List<AppLogRecord> _ring = <AppLogRecord>[];

  /// 仅测试可重置。
  @visibleForTesting
  static void resetRing() => _ring.clear();

  /// 当前缓冲快照（供设置页「导出诊断」）。
  static List<AppLogRecord> get records => List.unmodifiable(_ring);

  /// 渲染成可直接粘贴的文本（已脱敏）。
  static String exportText() => _ring.map((r) => r.toString()).join('\n');

  static void debug(String message, {String tag = 'Musaic'}) =>
      _write(AppLogLevel.debug, tag, message);

  static void info(String message, {String tag = 'Musaic'}) =>
      _write(AppLogLevel.info, tag, message);

  static void warning(String message, {String tag = 'Musaic'}) =>
      _write(AppLogLevel.warning, tag, message);

  static void error(
    String message, {
    String tag = 'Musaic',
    Object? error,
    StackTrace? stackTrace,
  }) {
    final buffer = StringBuffer(message);
    if (error != null) buffer.write(' | error=$error');
    if (stackTrace != null) {
      final head = stackTrace.toString().split('\n').take(4).join(' | ');
      buffer.write(' | stack=$head');
    }
    _write(AppLogLevel.error, tag, buffer.toString());
  }

  static void _write(AppLogLevel level, String tag, String message) {
    // 先脱敏，再进入任何输出通道。
    final safe = redactForLog(message);

    final record = AppLogRecord(
      level: level,
      tag: tag,
      message: safe,
      timestamp: DateTime.now(),
    );
    _ring.add(record);
    if (_ring.length > ringCapacity) {
      _ring.removeRange(0, _ring.length - ringCapacity);
    }

    // release 下也保留 warning/error：真机排障依赖它。
    final enabled = kDebugMode || level.index >= AppLogLevel.warning.index;
    if (!enabled) return;

    developer.log(safe, name: tag, level: _levelValue(level));
  }

  static int _levelValue(AppLogLevel level) => switch (level) {
    AppLogLevel.debug => 500,
    AppLogLevel.info => 800,
    AppLogLevel.warning => 900,
    AppLogLevel.error => 1000,
  };
}
