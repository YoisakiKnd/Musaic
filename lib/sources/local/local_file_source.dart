import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/error/source_exception.dart';
import '../../core/model/track.dart';
import '../../core/source/capabilities.dart';
import '../../core/source/music_source.dart';
import '../../core/auth/auth_capability.dart';
import '../../core/auth/auth_result.dart';
import '../../core/lyrics/lrc_parser.dart';
import '../../core/lyrics/lyric_bundle.dart';
import 'id3_parser.dart';

/// 本地文件渠道（Master Plan §5.2，免登录）。
///
/// 扫描目录：应用文档目录/Musaic 与系统音乐目录；
/// 支持内嵌标签（ID3v2/v1）与内嵌封面；歌词优先同名 .lrc，其次 USLT。
class LocalFileSource extends MusicSource implements LibraryScanCapable {
  LocalFileSource({
    required super.credentialReader,
    Future<List<Directory>> Function()? directoryProvider,
    Future<Directory> Function()? coverCacheProvider,
  }) : _directoryProvider =
           directoryProvider ?? LocalFileSource.defaultDirectories,
       _coverCacheProvider =
           coverCacheProvider ?? LocalFileSource.defaultCoverCache;

  static const String id = 'local';

  /// 支持的音频扩展名。
  static const Set<String> audioExtensions = <String>{
    '.mp3',
    '.flac',
    '.m4a',
    '.aac',
    '.wav',
    '.ogg',
    '.opus',
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
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
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

  Future<List<Track>>? _activeScan;

  /// 扫描本地音乐库（结果缓存；force 重新扫描）。
  ///
  /// 全程在后台 isolate 执行（迭代计划 §9.3 / B13）：目录解析结果
  /// 传入后台，解析按批回传，UI isolate 不接触标签与封面原始字节。
  @override
  Future<List<Track>> scanLibrary({bool force = false}) {
    if (!force && _cache != null) return Future.value(_cache);
    if (force) _cache = null;
    return _activeScan ??= _scanNow().whenComplete(() => _activeScan = null);
  }

  Future<List<Track>> _scanNow() async {
    // 目录与封面缓存路径必须先在主 isolate 解析（path_provider 走平台通道）
    final dirs = await _directoryProvider();
    final coverDir = (await _coverCacheProvider()).path;
    final config = _ScanConfig(
      dirPaths: [for (final dir in dirs) dir.path],
      coverDirPath: coverDir,
    );
    final tracks = await _runScanIsolate(config);
    tracks.sort((a, b) => a.title.compareTo(b.title));
    return _cache = List.unmodifiable(tracks);
  }

  /// 启动扫描 isolate 并聚合批量回传结果；批次大小 [_scanBatchSize]。
  Future<List<Track>> _runScanIsolate(_ScanConfig config) async {
    final port = ReceivePort();
    final errors = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _scanIsolateEntry,
        (config, port.sendPort),
        onError: errors.sendPort,
        errorsAreFatal: true,
      );
      final tracks = <Track>[];
      final done = Completer<List<Track>>();
      late final StreamSubscription<dynamic> sub;
      late final StreamSubscription<dynamic> errSub;
      void finish() {
        errSub.cancel();
        sub.cancel();
        port.close();
        errors.close();
      }

      sub = port.listen((message) {
        if (done.isCompleted) return;
        if (message is String) {
          finish();
          done.completeError(StateError(message));
        } else if (message == null) {
          finish();
          done.complete(tracks);
        } else if (message is List) {
          tracks.addAll(message.cast<Track>());
        }
      });
      errSub = errors.listen((message) {
        if (done.isCompleted) return;
        finish();
        done.completeError(StateError('扫描 isolate 异常: $message'));
      });
      return await done.future;
    } finally {
      isolate?.kill(priority: Isolate.immediate);
    }
  }

  @override
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
      throw UnavailableStreamException('文件已被移动或删除', sourceId: sourceId);
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
      final bytes = await readTagBytes(File(filePath));
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

  /// 单文件构建 Track（主 isolate 调用，如详情补全）。
  Future<Track> _buildTrackFromFile(File file, {Track? fallback}) async {
    final coverDir = (await _coverCacheProvider()).path;
    final parsed = await parseTrackFile(file.path, coverDir);
    return _trackFromParsed(
      file.path,
      parsed,
      fallbackArtist: fallback?.artist,
      fallbackAlbum: fallback?.album,
      fallbackDuration: fallback?.duration,
      fallbackCoverUrl: fallback?.coverUrl,
    );
  }
}

/// 后台 isolate 扫描配置（主 isolate 解析后整体传入）。
class _ScanConfig {
  const _ScanConfig({required this.dirPaths, required this.coverDirPath});

  final List<String> dirPaths;
  final String coverDirPath;
}

/// 单批回传曲目数（迭代计划 §9.3：每 50～100 首回传一次）。
const int _scanBatchSize = 100;

/// 目录遍历最大深度，禁止无限制递归（迭代计划 §9.3）。
const int _maxScanDepth = 8;

/// 扫描时跳过的目录名（系统/构建缓存与杂项）。
const Set<String> _skippedDirNames = <String>{
  'node_modules',
  'build',
  'Cache',
  'Caches',
  'cache',
  'TemporaryItems',
  'Recovered Files',
};

/// 扫描 isolate 入口：有界遍历 → 逐文件解析 → 批量回传。
Future<void> _scanIsolateEntry((_ScanConfig, SendPort) input) async {
  final (config, sendPort) = input;
  try {
    final files = <String>[];
    for (final dirPath in config.dirPaths) {
      _collectAudioFiles(Directory(dirPath), files);
    }
    var pending = <Track>[];
    for (final path in files) {
      final parsed = await parseTrackFile(path, config.coverDirPath);
      pending.add(_trackFromParsed(path, parsed));
      if (pending.length >= _scanBatchSize) {
        sendPort.send(pending);
        pending = <Track>[];
      }
    }
    if (pending.isNotEmpty) sendPort.send(pending);
    sendPort.send(null); // 完成标记
  } catch (e) {
    sendPort.send('扫描失败: $e');
  }
}

/// 有界迭代遍历（深度 [_maxScanDepth]）：跳过隐藏目录与缓存目录，
/// 无权限/已删除目录静默跳过，避免无限制递归（迭代计划 §9.3）。
void _collectAudioFiles(Directory root, List<String> out) {
  final stack = <(Directory, int)>[(root, 0)];
  while (stack.isNotEmpty) {
    final (dir, depth) = stack.removeLast();
    final List<FileSystemEntity> children;
    try {
      children = dir.listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final entity in children) {
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      if (entity is Directory) {
        if (depth < _maxScanDepth && !_skippedDirNames.contains(name)) {
          stack.add((entity, depth + 1));
        }
      } else if (entity is File &&
          LocalFileSource.audioExtensions.contains(
            p.extension(entity.path).toLowerCase(),
          )) {
        out.add(entity.path);
      }
    }
  }
}

/// 单文件解析结果（标签与封面 URL）。
typedef ParsedTrack =
    ({String title, String artist, String? album, String? coverUrl});

/// 在后台 isolate 中解析单个音频文件：只读标签所需字节，封面落盘缓存。
Future<ParsedTrack> parseTrackFile(String path, String coverDirPath) async {
  var title = p.basenameWithoutExtension(path);
  String artist = '';
  String? album;
  Uint8List? coverBytes;

  try {
    final bytes = await readTagBytes(File(path));
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
    coverUrl = await persistCover(path, coverBytes, coverDirPath);
  }
  return (title: title, artist: artist, album: album, coverUrl: coverUrl);
}

Track _trackFromParsed(
  String path,
  ParsedTrack parsed, {
  String? fallbackArtist,
  String? fallbackAlbum,
  Duration? fallbackDuration,
  String? fallbackCoverUrl,
}) {
  return Track(
    id: path,
    sourceId: LocalFileSource.id,
    title: parsed.title,
    artist: parsed.artist.isEmpty ? (fallbackArtist ?? '未知歌手') : parsed.artist,
    album: parsed.album ?? fallbackAlbum,
    duration: fallbackDuration,
    coverUrl: parsed.coverUrl ?? fallbackCoverUrl,
    sourceData: <String, dynamic>{'path': path},
  );
}

/// 只读取标签所需字节，避免整文件载入内存（性能预算 §10.2）。
Future<Uint8List> readTagBytes(File file) async {
  final length = await file.length();
  const headBudget = 512 * 1024;
  final headSize = length < headBudget ? length : headBudget;

  final raf = await file.open();
  try {
    final head = await raf.read(headSize);
    final hasV2 =
        head.length >= 3 &&
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

/// 内嵌封面落盘：按路径哈希命名，已存在且大小一致则复用。
Future<String?> persistCover(
  String audioPath,
  Uint8List bytes,
  String coverDirPath,
) async {
  try {
    final dir = Directory(coverDirPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final name = '${_djb2(audioPath)}.jpg';
    final target = File(p.join(dir.path, name));
    if (!target.existsSync() || target.lengthSync() != bytes.length) {
      await target.writeAsBytes(bytes, flush: true);
    }
    return Uri.file(target.path).toString();
  } catch (_) {
    return null;
  }
}

String _djb2(String input) {
  var hash = 5381;
  for (final code in utf8.encode(input)) {
    hash = ((hash << 5) + hash + code) & 0x7FFFFFFF;
  }
  return hash.toRadixString(36);
}
