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

  String encodePretty() => const JsonEncoder.withIndent('  ').convert(toJson());

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
    List<Track> tracks(Object? raw) =>
        raw is List
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
      exportedAt: DateTime.tryParse('${json['exportedAt']}') ?? DateTime.now(),
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
///
/// 导入前完整校验，导入中任一步骤失败都回滚到导入前快照，
/// 保证「备份导入失败时本地数据保持不变」（迭代计划 §8.6 / B17）。
class BackupService {
  BackupService({required LibraryRepository library}) : _library = library;

  /// 导入文件大小上限：超出视为坏包直接拒绝。
  static const int maxImportFileBytes = 32 * 1024 * 1024;

  final LibraryRepository _library;

  LibraryBackup snapshot() => LibraryBackup(
    favorites: _library.favorites,
    playlists: _library.playlistSnapshot(),
    history: _library.recentHistory(limit: LibraryRepository.historyCap),
    exportedAt: DateTime.now(),
  );

  /// 从备份文件字节解析；大小、编码、JSON、schema、结构任一非法抛 FormatException。
  LibraryBackup decodeBytes(List<int> bytes) {
    if (bytes.length > maxImportFileBytes) {
      throw FormatException(
        '备份文件过大（${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB，'
        '上限 ${maxImportFileBytes ~/ (1024 * 1024)} MB）',
      );
    }
    final String raw;
    try {
      raw = utf8.decode(bytes);
    } on FormatException {
      throw const FormatException('备份文件不是 UTF-8 文本');
    }
    return decode(raw);
  }

  /// 解析备份 JSON；格式非法抛 FormatException。
  LibraryBackup decode(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('备份文件不是合法 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('备份文件根节点须为 JSON 对象');
    }
    final schema = decoded['schema'];
    if (schema is! int || schema < 1 || schema > LibraryBackup.currentSchema) {
      throw FormatException(
        '不支持的备份版本：$schema（当前支持 1~${LibraryBackup.currentSchema}）',
      );
    }
    final Object? exportedAt = decoded['exportedAt'];
    if (exportedAt is! String ||
        (exportedAt.isNotEmpty && DateTime.tryParse(exportedAt) == null)) {
      throw const FormatException('备份时间字段格式非法');
    }
    final Object? favorites = decoded['favorites'];
    final Object? history = decoded['history'];
    final Object? playlists = decoded['playlists'];
    if (favorites != null && favorites is! List) {
      throw const FormatException('收藏字段须为数组');
    }
    if (history != null && history is! List) {
      throw const FormatException('历史字段须为数组');
    }
    if (playlists != null && playlists is! Map) {
      throw const FormatException('歌单字段须为对象');
    }
    try {
      return LibraryBackup.fromJson(decoded);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('备份内容结构非法，曲目解析失败');
    }
  }

  /// 合并导入：收藏/历史并集，歌单按名合并去重（新建缺失歌单）。
  ///
  /// 导入前捕获全库快照；任一写入失败（曲目结构、歌单名校验、
  /// 磁盘错误等）即回滚到导入前状态并向上抛出。
  Future<BackupImportResult> importBackup(LibraryBackup backup) async {
    final snapshot = _library.captureSnapshot();
    try {
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
    } on Object catch (_) {
      // 导入失败：恢复导入前快照，本地数据保持不变
      await _library.restoreSnapshot(snapshot);
      rethrow;
    }
  }
}

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(library: ref.watch(libraryRepositoryProvider));
});
