import 'dart:convert';

import 'package:hive/hive.dart';

/// 搜索历史仓库（Hive 单键 JSON 数组，上限 15 条，最新在前）。
class SearchHistoryRepository {
  SearchHistoryRepository({required Box<String> box}) : _box = box;

  static const String boxName = 'musaic_search_history';
  static const String _key = 'history';
  static const int _cap = 15;

  final Box<String> _box;

  List<String> load() {
    final raw = _box.get(_key);
    if (raw == null) return const <String>[];
    try {
      final list = (jsonDecode(raw) as List<dynamic>)
          .whereType<String>()
          .toList();
      return List<String>.unmodifiable(list);
    } catch (_) {
      return const <String>[];
    }
  }

  /// 记录一次搜索：去重置顶，超限裁剪。
  Future<List<String>> add(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return load();
    final next = <String>[
      trimmed,
      ...load().where((k) => k != trimmed),
    ];
    final capped = next.take(_cap).toList();
    await _box.put(_key, jsonEncode(capped));
    return List<String>.unmodifiable(capped);
  }

  Future<List<String>> clear() async {
    await _box.delete(_key);
    return const <String>[];
  }
}
