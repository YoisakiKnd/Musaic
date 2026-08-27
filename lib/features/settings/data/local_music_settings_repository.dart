import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 本地音乐设置仓库：扫描文件夹列表 + 扫描偏好（Hive 持久化）。
///
/// 从设置页面文件中拆出：仓库与 Provider 属于数据层，
/// 组合根（main / app_providers）只依赖本文件，不依赖 UI。
class LocalMusicSettingsRepository {
  LocalMusicSettingsRepository({required this.box});

  static const String boxName = 'local_music_settings';
  static const String _foldersKey = 'folders';
  static const String _autoScanKey = 'auto_scan';

  final Box<String> box;

  /// 用户添加的扫描文件夹（绝对路径）。
  List<String> get folders {
    final raw = box.get(_foldersKey);
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.whereType<String>().toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  Future<void> addFolder(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return;
    final current = folders;
    if (current.contains(trimmed)) return;
    await box.put(_foldersKey, jsonEncode([...current, trimmed]));
  }

  Future<void> removeFolder(String path) async {
    final current = folders.where((f) => f != path).toList(growable: false);
    await box.put(_foldersKey, jsonEncode(current));
  }

  /// 启动时自动扫描本地库。
  bool get autoScanOnStartup => box.get(_autoScanKey) == 'true';

  Future<void> setAutoScanOnStartup(bool value) =>
      box.put(_autoScanKey, value ? 'true' : 'false');

  /// 常见音乐目录预设（存在才展示）。
  static Future<List<String>> presetCandidates() async {
    final candidates = <String>[
      '/storage/emulated/0/Music',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/netease/cloudmusic-Music',
      '/storage/emulated/0/kgmusic/download',
      '/storage/emulated/0/qqmusic/song',
      if (!Platform.isAndroid)
        Platform.environment['HOME'] != null
            ? p.join(Platform.environment['HOME']!, 'Music')
            : '',
    ];
    return candidates
        .where((path) => path.isNotEmpty && Directory(path).existsSync())
        .toList(growable: false);
  }

  /// 应用文档目录下的 Musaic 文件夹（内置目录，无需权限）。
  static Future<String?> defaultAppFolder() async {
    try {
      final documents = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(documents.path, 'Musaic'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir.path;
    } catch (_) {
      return null;
    }
  }
}

final localMusicSettingsRepositoryProvider =
    Provider<LocalMusicSettingsRepository>((ref) {
  throw StateError('localMusicSettingsRepositoryProvider 必须在启动时 override');
});
