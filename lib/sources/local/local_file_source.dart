import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
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

  /// 内嵌封面落盘目录。
  ///
  /// 放在**应用支持目录**而非临时目录：系统可随时清理 temp，
  /// 会导致已扫描曲目的封面 URL 失效（列表封面集体变占位图）。
  /// 支持目录由应用负责清理，配合 `_djb2(path)` 命名可复用已有文件。
  static Future<Directory> defaultCoverCache() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'musaic_covers'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  // ---------- 音乐能力 ----------

  Future<List<Track>>? _activeScan;

  /// 扫描本地音乐库（结果缓存；force 重新扫描）。
  ///
  /// 全程在后台 isolate 执行（迭代计划 §9.3 / B13）：目录解析结果
  /// 传入后台，解析按批回传，UI isolate 不接触标签与封面原始字节。
  ///
  /// 注意 `force: true` 语义：用户在设置里新增/更换了目录后必须**重扫**，
  /// 若直接复用进行中的 `_activeScan`（旧目录配置），新目录会被静默忽略。
  /// 因此 force 时放弃旧句柄、按当前目录重新起一次扫描。
  @override
  Future<List<Track>> scanLibrary({bool force = false}) {
    if (!force && _cache != null) return Future.value(_cache);
    if (!force) {
      return _activeScan ??= _scanNow().whenComplete(() => _activeScan = null);
    }
    _cache = null;
    late Future<List<Track>> scan;
    scan = _scanNow().whenComplete(() {
      // 仅当自己仍是当前句柄时才清空，避免覆盖后发起的那一次
      if (identical(_activeScan, scan)) _activeScan = null;
    });
    _activeScan = scan;
    return scan;
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
    final filePath = localFilePathOf(track);
    if (filePath == null) return track;
    final file = File(filePath);
    if (!file.existsSync()) return track;
    return _buildTrackFromFile(file, fallback: track);
  }

  @override
  Future<ResolvedStream> resolveStream(Track track) async {
    // 只认路径，不认 id：新数据的 id 是内容指纹（`local:<size>:<hash>`），
    // 路径只存在 sourceData 里；旧数据的 id 就是路径，由 localFilePathOf 兜底。
    final filePath = localFilePathOf(track);
    if (filePath == null || !File(filePath).existsSync()) {
      throw UnavailableStreamException('文件已被移动或删除', sourceId: sourceId);
    }
    return ResolvedStream(url: filePath, isLocalFile: true);
  }

  /// 歌词：同名 .lrc > 内嵌 USLT(含时间戳时按 LRC 解析) > 无。
  @override
  Future<LyricBundle?> fetchLyrics(Track track) async {
    final filePath = localFilePathOf(track);
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

/// 单文件解析结果（标签与封面 URL + 稳定 id 所需的内容指纹）。
///
/// [fileSize] 与 [headHash] 由解析时顺带算出：扫描已经在后台 isolate 读文件，
/// 复用同一次 IO 顺带取指纹，避免主 isolate 为算 id 再读一遍磁盘。
typedef ParsedTrack =
    ({
      String title,
      String artist,
      String? album,
      String? coverUrl,
      int fileSize,
      String headHash,
    });

/// 在后台 isolate 中解析单个音频文件：只读标签所需字节，封面落盘缓存。
///
/// 同时返回内容指纹（文件大小 + 前 64KB 哈希），供 [localTrackIdFor] 生成稳定 id。
Future<ParsedTrack> parseTrackFile(String path, String coverDirPath) async {
  var title = p.basenameWithoutExtension(path);
  String artist = '';
  String? album;
  Uint8List? coverBytes;
  // 指纹默认值：文件不可读（权限/已删除）时退化为「大小 0 + 空哈希」，
  // 此时同一目录下的坏文件会撞 id，但坏文件本来就无法播放，不影响正常曲目。
  var fileSize = 0;
  var headHash = '';

  final file = File(path);
  // 指纹与标签分开 try：指纹读取失败不应连累标签解析（反之亦然），
  // 两者各自退回默认值，保证「文件读得到多少就用多少」。
  try {
    fileSize = await file.length();
    headHash = await readHeadHash(file);
  } catch (_) {
    // 文件不可读：保留默认指纹，交给下面的标签分支再试一次
  }

  try {
    final bytes = await readTagBytes(file);
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
  return (
    title: title,
    artist: artist,
    album: album,
    coverUrl: coverUrl,
    fileSize: fileSize,
    headHash: headHash,
  );
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
    // id 用内容指纹而非路径：移动 / 重命名文件后，收藏与歌单里的本地曲目
    // 仍然指向同一首（路径变化不再让记录静默失效）。真实路径照旧写进
    // sourceData，播放时以它为准。
    id: localTrackIdFor(fileSize: parsed.fileSize, headHash: parsed.headHash),
    sourceId: LocalFileSource.id,
    title: parsed.title,
    artist: parsed.artist.isEmpty ? (fallbackArtist ?? '未知歌手') : parsed.artist,
    album: parsed.album ?? fallbackAlbum,
    duration: fallbackDuration,
    coverUrl: parsed.coverUrl ?? fallbackCoverUrl,
    sourceData: <String, dynamic>{'path': path},
  );
}

/// 本地曲目稳定 id：优先内容指纹，路径仅作兜底。
///
/// 返回形如 `local:<size>:<headHash>` 的稳定标识。同一文件被移动 / 重命名 /
/// 换容器目录（macOS/iOS 沙盒路径会随版本变化）后，只要内容不变，
/// id 就不变，收藏与歌单里的引用不会静默失效。
///
/// 纯函数：不碰文件系统，便于单测。
String localTrackIdFor({required int fileSize, required String headHash}) =>
    'local:$fileSize:$headHash';

/// 取本地曲目应播放的真实路径。
///
/// 优先 `sourceData['path']`（当前写法）；缺失时回退到 `id`——**旧数据**的
/// id 就是绝对路径，没有这一步升级后老收藏会全部播不了。兜底只在 id 长得
/// 像绝对路径（`/` 开头，或 Windows 盘符 `C:\`）时生效，避免把
/// `local:<size>:<hash>` 这种指纹误当成路径。
String? localFilePathOf(Track track) {
  final path = track.sourceData?['path'];
  if (path is String && path.trim().isNotEmpty) return path;
  final id = track.id;
  if (id.startsWith('/')) return id;
  if (_windowsDrivePathPattern.hasMatch(id)) return id;
  return null;
}

/// Windows 绝对路径形态：盘符 + `:` + `\` 或 `/`。
final RegExp _windowsDrivePathPattern = RegExp(r'^[A-Za-z]:[\\/]');

/// 文件头部采样长度：只看头部是因为音频文件动辄几十 MB，
/// 全文件哈希的 IO 代价无法接受；而容器头 + 首批音频帧
/// 足以区分绝大多数曲目（同大小同头部的不同曲目极罕见）。
const int _headHashBytes = 64 * 1024;

/// 读取文件前 64KB 的 sha1 十六进制摘要（IO 由调用方所在 isolate 承担）。
Future<String> readHeadHash(File file) async {
  final raf = await file.open();
  try {
    final head = await raf.read(_headHashBytes);
    return crypto.sha1.convert(head).toString();
  } finally {
    await raf.close();
  }
}

/// 只读取标签所需字节，避免整文件载入内存（性能预算 §10.2）。
///
/// 固定 512KB 头预算会**截断** ID3v2 标签：标签头里的 synchsafe 长度
/// 声明了真实大小，若超过预算，帧循环会在标签中间提前 break，
/// 静默丢掉封面/歌词等字段（大内嵌封面专辑很常见）。
/// 因此先读 10 字节标签头拿到声明长度，再按需读取（带上限兜底）。
Future<Uint8List> readTagBytes(File file) async {
  final length = await file.length();
  const headBudget = 512 * 1024;

  /// 标签体上限：防止畸形文件声明超大长度导致巨额内存分配。
  const maxTagBody = 8 * 1024 * 1024;

  final raf = await file.open();
  try {
    // 先读标签头（ID3v2 头固定 10 字节）
    final header = await raf.read(10);
    final hasV2 =
        header.length >= 3 &&
        header[0] == 0x49 &&
        header[1] == 0x44 &&
        header[2] == 0x33;

    int headSize;
    if (hasV2 && header.length >= 10) {
      // synchsafe：每字节仅低 7 位有效
      final declared =
          ((header[6] & 0x7F) << 21) |
          ((header[7] & 0x7F) << 14) |
          ((header[8] & 0x7F) << 7) |
          (header[9] & 0x7F);
      final total = (declared + 10).clamp(10, maxTagBody);
      headSize = total < length ? total : length;
    } else {
      headSize = length < headBudget ? length : headBudget;
    }

    await raf.setPosition(0);
    final head = await raf.read(headSize);
    if (hasV2 || length <= headSize) return head;
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
