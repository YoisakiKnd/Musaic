import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/model/track.dart';
import '../../core/source/music_source.dart';

/// 本地文件音乐渠道。
///
/// 扫描设备本地音频文件，免登录。
class LocalFileSource extends MusicSource {
  LocalFileSource({Set<String>? supportedExtensions})
      : _supportedExtensions = supportedExtensions ??
            const {'.mp3', '.flac', '.m4a', '.aac', '.ogg', '.wav', '.wma'};

  final Set<String> _supportedExtensions;

  @override
  String get sourceId => 'local';

  @override
  String get sourceName => '本地文件';

  @override
  Future<List<Track>> search(String query) async {
    final directories = await _scanDirectories();
    final allTracks = <Track>[];
    for (final dir in directories) {
      allTracks.addAll(await _scanDirectory(dir, query));
    }
    return allTracks;
  }

  @override
  Future<Track> getTrackDetail(Track track) async => track;

  @override
  Future<String> getStreamUrl(Track track) async {
    if (track.sourceId != sourceId) {
      throw ArgumentError('Track does not belong to local source');
    }
    final path = track.sourceData?['path'] as String?;
    if (path == null || path.isEmpty) {
      throw ArgumentError('Track missing local path');
    }
    return Uri.file(path).toString();
  }

  @override
  Future<String?> getLyrics(Track track) async => null;

  Future<List<Track>> scanAll({String? query}) => search(query ?? '');

  Future<List<Directory>> _scanDirectories() async {
    final dirs = <Directory>[];
    final appDir = await getApplicationDocumentsDirectory();
    dirs.add(appDir);

    if (Platform.isAndroid || Platform.isIOS) {
      final external = await getExternalStorageDirectory();
      if (external != null) dirs.add(external);
    }

    return dirs;
  }

  Future<List<Track>> _scanDirectory(Directory dir, String query) async {
    final results = <Track>[];

    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (!_supportedExtensions.contains(ext)) continue;

          final filename = p.basenameWithoutExtension(entity.path);
          if (query.isNotEmpty &&
              !filename.toLowerCase().contains(query.toLowerCase())) {
            continue;
          }

          results.add(
            Track(
              id: entity.path,
              sourceId: sourceId,
              title: filename,
              artist: '本地音乐',
              album: p.basename(entity.parent.path),
              sourceData: {'path': entity.path},
            ),
          );
        }
      }
    } catch (_) {
      // ignore unreadable directories
    }

    return results;
  }
}
