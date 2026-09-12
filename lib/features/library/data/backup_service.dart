import 'dart:async';
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

/// 本地文件渠道标识，与 `sources/local/local_file_source.dart` 的
/// `LocalFileSource.id` 保持一致。
///
/// 这里独立声明常量而非 import：架构守护测试禁止 `features/` 直接依赖
/// `sources/`（渠道只能经 SourceRegistry 消费）。
const String _localSourceId = 'local';

/// 非本地曲目的伪 URI 前缀：`musaic://<sourceId>/<id>`。
///
/// 各渠道的定位符（neteaseId / songmid / videoId…）互不通用，
/// 但 [Track.key] 只需要 `sourceId + id`，因此伪 URI 足以保证
/// 导出→导入后仍是同一首歌（N2 要求可往返）。
const String _m3uUriPrefix = 'musaic://';

/// 标准 m3u 头。
const String _m3uHeader = '#EXTM3U';

/// `#PLAYLIST:` 扩展头（非标准，但被广泛支持，用于携带歌单名）。
const String _m3uPlaylistPrefix = '#PLAYLIST:';

/// `#EXTINF:` 条目头。
const String _m3uExtInfPrefix = '#EXTINF:';

/// 把任意文本压成单行：m3u 是行格式，标题里的换行会伪造出条目行。
String _m3uSanitize(String value) =>
    value.replaceAll('\r', ' ').replaceAll('\n', ' ');

/// 曲目在 m3u 中的定位符。
///
/// 本地渠道优先写真实文件路径——这样导出的 m3u 也能被 VLC 等
/// 外部播放器直接打开；其余渠道没有通用定位符，退化为伪 URI。
String _m3uLocationOf(Track track) {
  if (track.sourceId == _localSourceId) {
    final path = track.sourceData?['path'];
    if (path is String && path.trim().isNotEmpty) return path.trim();
  }
  return '$_m3uUriPrefix${Uri.encodeComponent(track.sourceId)}'
      '/${Uri.encodeComponent(track.id)}';
}

/// 解析伪 URI；返回 null 表示「不是 musaic 伪 URI」（按本地路径处理）。
///
/// 结构非法（缺 sourceId / 缺 id / 百分号编码坏掉）时返回 null，
/// 由调用方跳过该行而不是抛错。
({String sourceId, String id})? _parseM3uUri(String location) {
  if (!location.startsWith(_m3uUriPrefix)) return null;
  final rest = location.substring(_m3uUriPrefix.length);
  final slash = rest.indexOf('/');
  if (slash <= 0 || slash == rest.length - 1) return null;
  try {
    return (
      sourceId: Uri.decodeComponent(rest.substring(0, slash)),
      id: Uri.decodeComponent(rest.substring(slash + 1)),
    );
  } on Object {
    // 非法百分号编码（如 `musaic://a/%ZZ`）：视为坏行跳过。
    return null;
  }
}

/// 无 `#EXTINF` 的裸条目：标题退回定位符的最后一段。
String _m3uFallbackTitle(String location) {
  final cut = location.lastIndexOf(RegExp(r'[/\\]'));
  return cut < 0 ? location : location.substring(cut + 1);
}

/// 解析 `#EXTINF:<秒数>,<展示名>`。
///
/// 兼容 IPTV 风格 `#EXTINF:-1 tvg-id="x",名称`：时长只取首个数字 token。
/// 时长缺失 / 非法 / 为负（m3u 惯例用 -1 表示未知）时返回 null。
({Duration? duration, String label}) _parseM3uExtInf(String line) {
  final body = line.substring(_m3uExtInfPrefix.length);
  final comma = body.indexOf(',');
  final head = comma < 0 ? body : body.substring(0, comma);
  final label = comma < 0 ? '' : body.substring(comma + 1).trim();
  final match = RegExp(r'^\s*(-?\d+(?:\.\d+)?)').firstMatch(head);
  Duration? duration;
  final token = match?.group(1);
  final seconds = token == null ? null : double.tryParse(token);
  if (seconds != null && seconds > 0) {
    // 上限一天：避免坏数据（如 `#EXTINF:1e12`）生成荒谬的 Duration。
    final ms = (seconds * 1000).round().clamp(0, 86400000);
    duration = Duration(milliseconds: ms);
  }
  return (duration: duration, label: label);
}

/// 把 `<歌手> - <标题>` 拆回两段。
///
/// 以首个 ` - ` 为界：这是编码时的写法。标题自身含 ` - ` 时无法
/// 完全还原（m3u 的 EXTINF 本就不区分两者），但 [Track.key] 不受影响。
({String artist, String title}) _splitM3uLabel(
  String label,
  String fallbackTitle,
) {
  final separator = label.indexOf(' - ');
  if (separator < 0) {
    return (artist: '', title: label.isEmpty ? fallbackTitle : label);
  }
  final artist = label.substring(0, separator).trim();
  final title = label.substring(separator + 3).trim();
  return (artist: artist, title: title.isEmpty ? fallbackTitle : title);
}

/// 编码为 m3u 文本（纯函数，便于单测）。
///
/// 格式：
/// ```
/// #EXTM3U
/// #PLAYLIST:<歌单名>          （playlistName 非空时才有）
/// #EXTINF:<秒数>,<歌手> - <标题>
/// <定位符>
/// ```
/// 时长缺失写 `-1`（m3u 通用约定）；定位符策略见 [_m3uLocationOf]。
String encodeM3u(Iterable<Track> tracks, {String? playlistName}) {
  final buffer = StringBuffer('$_m3uHeader\n');
  final name = playlistName?.trim() ?? '';
  if (name.isNotEmpty) {
    buffer.write('$_m3uPlaylistPrefix${_m3uSanitize(name)}\n');
  }
  for (final track in tracks) {
    // 秒级精度：整数秒是各播放器兼容性最好的写法（毫秒会被截断）。
    final seconds = track.duration?.inSeconds ?? -1;
    final artist = _m3uSanitize(track.artist);
    final title = _m3uSanitize(track.title);
    buffer.write('$_m3uExtInfPrefix$seconds,$artist - $title\n');
    buffer.write('${_m3uSanitize(_m3uLocationOf(track))}\n');
  }
  return buffer.toString();
}

/// 解析 m3u 文本（纯函数，便于单测）。
///
/// 只识别 `#EXTINF:` 与 `#PLAYLIST:`；其余 `#` 行（注释、`#EXTGRP` 等）
/// 一律忽略；非 `#` 行视为条目，坏行跳过而不抛错。
/// 返回顺序与文件一致，因此 `decodeM3u(encodeM3u(x))` 可往返（key 一致）。
List<Track> decodeM3u(String content) {
  final tracks = <Track>[];
  Duration? pendingDuration;
  String pendingLabel = '';
  var hasExtInf = false;
  for (final rawLine in const LineSplitter().convert(content)) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      if (line.startsWith(_m3uExtInfPrefix)) {
        final parsed = _parseM3uExtInf(line);
        pendingDuration = parsed.duration;
        pendingLabel = parsed.label;
        hasExtInf = true;
      }
      continue;
    }
    final uri = _parseM3uUri(line);
    final String sourceId;
    final String id;
    if (uri != null) {
      sourceId = uri.sourceId;
      id = uri.id;
    } else if (line.startsWith(_m3uUriPrefix)) {
      continue; // 形如伪 URI 但结构非法：坏行，跳过
    } else {
      sourceId = _localSourceId; // 裸路径按本地文件处理（m3u 通用语义）
      id = line;
    }
    final split = _splitM3uLabel(pendingLabel, _m3uFallbackTitle(id));
    tracks.add(
      Track(
        id: id,
        sourceId: sourceId,
        title: split.title,
        artist: split.artist,
        duration: hasExtInf ? pendingDuration : null,
        // 本地曲目要带回路径，否则导入后无法解析音频流。
        sourceData:
            sourceId == _localSourceId ? <String, dynamic>{'path': id} : null,
      ),
    );
    pendingDuration = null;
    pendingLabel = '';
    hasExtInf = false;
  }
  return tracks;
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

  /// 导出指定歌单为 m3u 文本（歌单不存在则只有头，不抛错）。
  String exportM3u(String playlistName) => encodeM3u(
    _library.playlistTracks(playlistName),
    playlistName: playlistName,
  );

  /// 导入 m3u 文本到指定歌单，返回实际解析出的条数。
  ///
  /// 歌单已存在则**合并**（[LibraryRepository.addManyToPlaylist] 按 key
  /// 去重），不会覆盖本地已有曲目；文本为空时返回 0 且不建歌单。
  Future<int> importM3u(String content, {required String playlistName}) async {
    final tracks = decodeM3u(content);
    if (tracks.isEmpty) return 0;
    // 与 importBackup 一致：先建歌单（幂等）再批量写入，只做一次读-改-写。
    await _library.createPlaylist(playlistName);
    await _library.addManyToPlaylist(playlistName, tracks);
    return tracks.length;
  }

  /// 合并导入：收藏/历史并集，歌单按名合并去重（新建缺失歌单）。
  ///
  /// 导入前捕获全库快照；任一写入失败（曲目结构、歌单名校验、
  /// 磁盘错误等）即回滚到导入前状态并向上抛出。
  ///
  /// 整个导入 + 回滚过程持有一把全局互斥锁：否则导入期间用户的一次
  /// 收藏/建歌单写入会被回滚快照静默抹掉（P1 数据安全回归）。
  Future<BackupImportResult> importBackup(LibraryBackup backup) {
    final previous = _importLock;
    final current = Completer<void>();
    _importLock = current.future;
    return previous
        .then((_) => _runImport(backup))
        .whenComplete(current.complete);
  }

  Future<void> _importLock = Future<void>.value();

  Future<BackupImportResult> _runImport(LibraryBackup backup) async {
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
    } on Object {
      // 导入失败：恢复导入前快照，本地数据保持不变。
      // 回滚自身若也失败，不能吞掉原始异常——两者都要暴露。
      try {
        await _library.restoreSnapshot(snapshot);
      } on Object catch (rollbackError) {
        throw StateError('导入失败且回滚失败：$rollbackError');
      }
      rethrow;
    }
  }
}

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(library: ref.watch(libraryRepositoryProvider));
});
