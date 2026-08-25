import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/error/source_exception.dart';
import '../../core/model/track.dart';
import '../../core/source/music_source.dart';
import '../../features/auth/domain/auth_capability.dart';
import '../../features/auth/domain/auth_result.dart';
import '../../features/lyrics/domain/lrc_parser.dart';
import '../../features/lyrics/domain/lyric_bundle.dart';
import 'id3_parser.dart';

/// 本地文件渠道（Master Plan §5.2，免登录）。
///
/// 扫描目录：应用文档目录/Musaic 与系统音乐目录；
/// 支持内嵌标签（ID3v2/v1）与内嵌封面；歌词优先同名 .lrc，其次 USLT。
class LocalFileSource extends MusicSource {
  LocalFileSource({
    required super.credentialReader,
    Future<List<Directory>> Function()? directoryProvider,
    Future<Directory> Function()? coverCacheProvider,
  })  : _directoryProvider =
            directoryProvider ?? LocalFileSource.defaultDirectories,
        _coverCacheProvider =
            coverCacheProvider ?? LocalFileSource.defaultCoverCache;

  static const String id = 'local';

  /// 支持的音频扩展名。
  static const Set<String> audioExtensions = <String>{
    '.mp3', '.flac', '.m4a', '.aac', '.wav', '.ogg', '.opus',
  };

  @override
  String get sourceId => LocalFileSource.id;

  @override
  String get displayName => '本地文件';

  @override
  AuthCapability get authCapability => AuthCapability.noAuth;

  final Future<List<Directory>> Function() _directoryProvider;
  final Future<Directory> Function() _coverCacheProvider;

  List<Track>? _cache;

  /// 默认扫描目录：文档目录/Musaic + 系统音乐目录（桌面端）。
  static Future<List<Directory>> defaultDirectories() async {
    final dirs = <Directory>[];
    try {
      final documents = await getApplicationDocumentsDirectory();
      dirs.add(Directory(p.join(documents.path, 'Musaic')));
    } catch (_) {}
    final home =
        Platform.environment['HOME'] ??
            Platform.environment['USERPROFILE'];
    if (home != null) {
      final music = Directory(p.join(home, 'Music'));
      if (music.existsSync()) dirs.add(music);
    }
    return dirs.where((d) => d.existsSync()).toList();
  }

  static Future<Directory> defaultCoverCache() async {
    final temp = await getTemporaryDirectory();
    final dir = Directory(p.join(temp.path, 'musaic_covers'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  // ---------- 音乐能力 ----------

  /// 扫描本地音乐库（结果缓存；force 重新扫描）。
  Future<List<Track>> scanLibrary({bool force = false}) async {
    if (!force && _cache != null) return _cache!;
    final dirs = await _directoryProvider();
    final tracks = <Track>[];
    for (final dir in dirs) {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (!audioExtensions
            .contains(p.extension(entity.path).toLowerCase())) {
          continue;
        }
        tracks.add(await _buildTrackFromFile(entity));
      }
    }
    tracks.sort((a, b) => a.title.compareTo(b.title));
    _cache = tracks;
    return tracks;
  }

  void invalidateScanCache() => _cache = null;

  @override
  Future<List<Track>> search(
    String query, {
    int limit = 30,
    int offset = 0,
  }) async {
    final library = await scanLibrary();
    final keyword = query.trim().toLowerCase();
    if (keyword.isEmpty) {
      return library.take(limit + offset).skip(offset).toList();
    }
    final matched = library
        .where(
          (t) =>
              t.title.toLowerCase().contains(keyword) ||
              t.artist.toLowerCase().contains(keyword) ||
              (t.album?.toLowerCase().contains(keyword) ?? false),
        )
        .toList(growable: false);
    return matched.skip(offset).take(limit).toList(growable: false);
  }

  @override
  Future<Track> getTrackDetail(Track track) async {
    final filePath = track.sourceData?['path'] as String?;
    if (filePath == null) return track;
    final file = File(filePath);
    if (!file.existsSync()) return track;
    return _buildTrackFromFile(file, fallback: track);
  }

  @override
  Future<ResolvedStream> resolveStream(Track track) async {
    final filePath = track.sourceData?['path'] as String?;
    if (filePath == null || !File(filePath).existsSync()) {
      throw UnavailableStreamException(
        '文件已被移动或删除',
        sourceId: sourceId,
      );
    }
    return ResolvedStream(url: filePath, isLocalFile: true);
  }

  /// 歌词：同名 .lrc > 内嵌 USLT(含时间戳时按 LRC 解析) > 无。
  @override
  Future<LyricBundle?> fetchLyrics(Track track) async {
    final filePath = track.sourceData?['path'] as String?;
    if (filePath == null) return null;

    final lrcPath = '${p.withoutExtension(filePath)}.lrc';
    final lrcFile = File(lrcPath);
    if (lrcFile.existsSync()) {
      try {
        final content = lrcFile.readAsStringSync();
        final bundle = LrcParser.parse(content);
        if (!bundle.isEmpty) return bundle;
      } catch (_) {}
    }

    try {
      final bytes = await _readTagBytes(File(filePath));
      final tags = Id3Parser.parse(bytes);
      final embedded = tags?.lyrics;
      if (embedded != null && embedded.contains('[')) {
        final bundle = LrcParser.parse(embedded);
        if (!bundle.isEmpty) return bundle;
      }
    } catch (_) {}
    return null;
  }

  // ---------- 账号能力 ----------

  @override
  Future<AuthResult> login(Map<String, String> credentials) async =>
      const AuthFailure(
        reason: AuthFailureReason.unsupported,
        message: '本地文件渠道无需登录',
      );

  // ---------- 内部 ----------

  Future<Track> _buildTrackFromFile(
    File file, {
    Track? fallback,
  }) async {
    var title = p.basenameWithoutExtension(file.path);
    String artist = '';
    String? album;
    Uint8List? coverBytes;

    try {
      final bytes = await _readTagBytes(file);
      final tags = Id3Parser.parse(bytes);
      if (tags != null) {
        if (tags.title?.isNotEmpty ?? false) title = tags.title!;
        if (tags.artist?.isNotEmpty ?? false) artist = tags.artist!;
        if (tags.album?.isNotEmpty ?? false) album = tags.album;
        coverBytes = tags.coverBytes;
      }
    } catch (_) {
      // 标签解析失败退回文件名
    }

    String? coverUrl;
    if (coverBytes != null) {
      coverUrl = await _persistCover(file.path, coverBytes);
    }

    return Track(
      id: file.path,
      sourceId: sourceId,
      title: title,
      artist: artist.isEmpty ? (fallback?.artist ?? '未知歌手') : artist,
      album: album ?? fallback?.album,
      duration: fallback?.duration,
      coverUrl: coverUrl ?? fallback?.coverUrl,
      sourceData: <String, dynamic>{'path': file.path},
    );
  }

  /// 只读取标签所需字节，避免整文件载入内存（性能预算 §10.2）。
  Future<Uint8List> _readTagBytes(File file) async {
    final length = await file.length();
    const headBudget = 512 * 1024;
    final headSize = length < headBudget ? length : headBudget;

    final raf = await file.open();
    try {
      final head = await raf.read(headSize);
      final hasV2 = head.length >= 3 &&
          head[0] == 0x49 &&
          head[1] == 0x44 &&
          head[2] == 0x33;
      if (hasV2 || length <= headBudget) return head;
      // 无 v2 头：补读尾部 128 字节供 ID3v1 判断
      await raf.setPosition(length - 128);
      final tail = await raf.read(128);
      return Uint8List.fromList([...head, ...tail]);
    } finally {
      await raf.close();
    }
  }

  Future<String?> _persistCover(String audioPath, Uint8List bytes) async {
    try {
      final cacheDir = await _coverCacheProvider();
      final name = '${_djb2(audioPath)}.jpg';
      final target = File(p.join(cacheDir.path, name));
      if (!target.existsSync() ||
          target.lengthSync() != bytes.length) {
        await target.writeAsBytes(bytes, flush: true);
      }
      return Uri.file(target.path).toString();
    } catch (_) {
      return null;
    }
  }

  static String _djb2(String input) {
    var hash = 5381;
    for (final code in utf8.encode(input)) {
      hash = ((hash << 5) + hash + code) & 0x7FFFFFFF;
    }
    return hash.toRadixString(36);
  }
}
