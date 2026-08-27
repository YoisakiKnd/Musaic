import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/model/track.dart';
import 'library_repository.dart';

/// 资料库备份快照（收藏 / 歌单 / 历史）——纯数据 + 编解码，无 IO，便于单测。
class LibraryBackup {
  const LibraryBackup({
    required this.favorites,
    required this.playlists,
    required this.history,
    required this.exportedAt,
    this.schema = 1,
  });

  static const int currentSchema = 1;

  /// 备份格式版本，便于将来向前兼容迁移。
  final int schema;
  final List<Track> favorites;

  /// 歌单名 → 曲目。
  final Map<String, List<Track>> playlists;
  final List<Track> history;
  final DateTime exportedAt;

  String encodePretty() =>
      const JsonEncoder.withIndent('  ').convert(toJson());

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema': schema,
        'exportedAt': exportedAt.toIso8601String(),
        'favorites': favorites.map((t) => t.toJson()).toList(),
        'playlists': <String, dynamic>{
          for (final e in playlists.entries)
            e.key: e.value.map((t) => t.toJson()).toList(),
        },
        'history': history.map((t) => t.toJson()).toList(),
      };

  factory LibraryBackup.fromJson(Map<String, dynamic> json) {
    List<Track> tracks(Object? raw) => raw is List
        ? raw
            .map((t) => Track.fromJson(Map<String, dynamic>.from(t as Map)))
            .toList()
        : const <Track>[];
    final pl = <String, List<Track>>{};
    final rawPl = json['playlists'];
    if (rawPl is Map) {
      for (final entry in rawPl.entries) {
        pl['${entry.key}'] = tracks(entry.value);
      }
    }
    return LibraryBackup(
      schema: json['schema'] as int? ?? 1,
      favorites: tracks(json['favorites']),
      playlists: pl,
      history: tracks(json['history']),
      exportedAt:
          DateTime.tryParse('${json['exportedAt']}') ?? DateTime.now(),
    );
  }
}

/// 导入结果统计。
class BackupImportResult {
  const BackupImportResult({
    required this.favorites,
    required this.playlists,
    required this.history,
  });

  final int favorites;
  final int playlists;
  final int history;
}

/// 备份服务：从当前资料库导出、合并式导入（按 key 去重，不覆盖本地已有）。
class BackupService {
  BackupService({required LibraryRepository library}) : _library = library;

  final LibraryRepository _library;

  LibraryBackup snapshot() => LibraryBackup(
        favorites: _library.favorites,
        playlists: _library.playlistSnapshot(),
        history: _library.recentHistory(
            limit: LibraryRepository.historyCap),
        exportedAt: DateTime.now(),
      );

  /// 解析备份 JSON；格式非法抛 FormatException。
  LibraryBackup decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('备份文件根节点须为 JSON 对象');
    }
    return LibraryBackup.fromJson(decoded);
  }

  /// 合并导入：收藏/历史并集，歌单按名合并去重（新建缺失歌单）。
  Future<BackupImportResult> importBackup(LibraryBackup backup) async {
    await _library.addAllFavorites(backup.favorites);
    await _library.bulkImportHistory(backup.history);
    for (final entry in backup.playlists.entries) {
      if (entry.value.isEmpty) continue;
      await _library.createPlaylist(entry.key);
      await _library.addManyToPlaylist(entry.key, entry.value);
    }
    return BackupImportResult(
      favorites: backup.favorites.length,
      playlists: backup.playlists.length,
      history: backup.history.length,
    );
  }
}

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(library: ref.watch(libraryRepositoryProvider));
});
