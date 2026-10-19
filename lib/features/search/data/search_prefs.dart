import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:meta/meta.dart';

/// 搜索页偏好：范围 / 渠道 / 结果展示 / 排序。
///
/// 此前全部是页面内存状态，每次重启都回到「单曲搜索 + 默认渠道」，
/// 用户每次都要重新点「聚合搜索」。
///
/// 聚合渠道存的是**排除**集合而非选中集合：以后新增渠道时默认参与搜索，
/// 而不是因为不在旧的选中列表里被悄悄漏掉。
@immutable
class SearchPrefs {
  const SearchPrefs({
    this.aggregate = true,
    this.singleTarget,
    this.excludedTargets = const <String>{},
    this.merged = false,
    this.sort = 'relevance',
  });

  /// 新用户默认聚合搜索：单渠道下很多歌搜不到（如周杰伦不在网易云），
  /// 而「多渠道聚合」本就是本应用的核心。
  final bool aggregate;
  final String? singleTarget;
  final Set<String> excludedTargets;
  final bool merged;
  final String sort;

  static const String storageKey = 'search_prefs';

  SearchPrefs copyWith({
    bool? aggregate,
    String? singleTarget,
    Set<String>? excludedTargets,
    bool? merged,
    String? sort,
  }) => SearchPrefs(
    aggregate: aggregate ?? this.aggregate,
    singleTarget: singleTarget ?? this.singleTarget,
    excludedTargets: excludedTargets ?? this.excludedTargets,
    merged: merged ?? this.merged,
    sort: sort ?? this.sort,
  );

  /// 读取；缺失或损坏时返回默认值（偏好丢了不该让搜索页起不来）。
  static SearchPrefs load(Box<String> box) {
    final raw = box.get(storageKey);
    if (raw == null) return const SearchPrefs();
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return SearchPrefs(
        aggregate: map['aggregate'] as bool? ?? true,
        singleTarget: map['single'] as String?,
        excludedTargets: {
          for (final id in (map['excluded'] as List<dynamic>? ?? const []))
            '$id',
        },
        merged: map['merged'] as bool? ?? false,
        sort: map['sort'] as String? ?? 'relevance',
      );
    } catch (_) {
      return const SearchPrefs();
    }
  }

  Future<void> save(Box<String> box) => box.put(
    storageKey,
    jsonEncode(<String, dynamic>{
      'aggregate': aggregate,
      if (singleTarget != null) 'single': singleTarget,
      'excluded': excludedTargets.toList()..sort(),
      'merged': merged,
      'sort': sort,
    }),
  );
}
