import 'dart:convert';

import 'package:dio/dio.dart';

import '../error/source_exception.dart';

/// 渠道响应解析工具（Master Plan §5.1）。
///
/// 四个渠道各自复制了 `_decoded` / `_asMap`，且大量使用
/// `json['x'] as int?` 这类非防御式强转：接口结构一旦漂移就抛
/// TypeError，而 `?? -1` 兜底根本走不到，异常还会逃出 `on DioException`
/// 的捕获范围。此模块提供安全读取器，统一替换这些强转。

/// 解析响应体：已解析的 Map/List 原样返回；
/// JSON 字符串（各渠道普遍使用 `ResponseType.plain`）解析为对象；
/// QQ 的 jsonp 包裹（`callback({...});`）会被剥壳；其余返回 null。
dynamic decodeResponseBody(Object? data) {
  if (data is! String) return data;
  final trimmed = data.trim();
  if (trimmed.isEmpty) return null;

  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      return jsonDecode(trimmed);
    } catch (_) {
      return null;
    }
  }

  // jsonp：`name({...})` / `name({...});`
  final jsonp = RegExp(
    r'^[^(]*\((.*)\);?\s*$',
    dotAll: true,
  ).firstMatch(trimmed);
  if (jsonp != null) {
    try {
      return jsonDecode(jsonp.group(1)!);
    } catch (_) {
      return null;
    }
  }
  return null;
}

/// 安全取 Map；非 Map 返回 null。
Map<String, dynamic>? asMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

/// 安全取 List；非 List 返回 null。
List<dynamic>? asList(Object? value) => value is List ? value : null;

/// 安全取 int：兼容 int / double / 数字字符串。
int? asIntOrNull(Object? value) {
  if (value is int) return value;
  if (value is double) return value.isFinite ? value.toInt() : null;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// 安全取 double。
double? asDoubleOrNull(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

/// 安全取 String：数字等标量转字符串，其余返回 null。
String? asStringOrNull(Object? value) {
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return null;
}

/// 安全取 bool：兼容 `1/0`、`"true"/"false"`。
bool? asBoolOrNull(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final t = value.trim().toLowerCase();
    if (t == 'true' || t == '1') return true;
    if (t == 'false' || t == '0') return false;
  }
  return null;
}

/// 网络异常 → 领域异常的统一映射（不含任何凭据信息）。
///
/// 渠道原先各自手写 `throw NetworkSourceException('X失败：网络异常')`，
/// 措辞与遗漏不一致；统一入口同时保留 [DioException.type] 便于诊断。
Never throwNetworkError(
  DioException error, {
  required String sourceId,
  required String action,
}) {
  throw NetworkSourceException(
    '$action失败：网络异常',
    sourceId: sourceId,
    cause: error,
  );
}
