import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 全局设置状态。

/// 主题模式（默认深色，符合设计令牌「深色优先」）。
final themeModeProvider = StateProvider<ThemeMode>(
  (_) => ThemeMode.dark,
);

/// 玻璃/模糊效果开关（性能预算 §10.2：低端机可关闭实时模糊）。
final enableGlassProvider = StateProvider<bool>((_) => true);
