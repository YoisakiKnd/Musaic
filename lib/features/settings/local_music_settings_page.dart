import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_tokens.dart';
import '../../sources/local/local_file_source.dart';

/// 本地音乐设置仓库：扫描文件夹列表 + 扫描偏好（Hive 持久化）。
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

/// 本地音乐设置页：扫描文件夹管理 + 扫描偏好 + 立即扫描。
class LocalMusicSettingsPage extends ConsumerStatefulWidget {
  const LocalMusicSettingsPage({super.key});

  @override
  ConsumerState<LocalMusicSettingsPage> createState() =>
      _LocalMusicSettingsPageState();
}

class _LocalMusicSettingsPageState
    extends ConsumerState<LocalMusicSettingsPage> {
  bool _scanning = false;
  int? _lastCount;

  @override
  void initState() {
    super.initState();
    _ensurePermission();
  }

  LocalMusicSettingsRepository get _repo =>
      ref.read(localMusicSettingsRepositoryProvider);

  /// Android 上扫描共享目录需媒体音频权限（API 33+ 为 READ_MEDIA_AUDIO）。
  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return true;
    var status = await Permission.audio.status;
    if (!status.isGranted) {
      status = await Permission.audio.request();
    }
    return status.isGranted;
  }

  Future<void> _scan() async {
    final local = ref
        .read(sourceRegistryProvider)
        .resolve(LocalFileSource.id) as LocalFileSource?;
    if (local == null) return;
    final permitted = await _ensurePermission();
    if (!mounted) return;
    if (!permitted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未授予音乐权限，无法扫描系统目录')),
      );
      return;
    }
    setState(() => _scanning = true);
    try {
      local.invalidateScanCache();
      final tracks = await local.scanLibrary(force: true);
      if (!mounted) return;
      setState(() => _lastCount = tracks.length);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('扫描完成，找到 ${tracks.length} 首歌曲')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('扫描失败，请检查目录与存储权限')),
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// 打开系统文件管理器（SAF）选择音乐文件夹。
  Future<void> _pickAndAddFolder() async {
    final permitted = await _ensurePermission();
    if (!mounted) return;
    if (!permitted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未授予音乐权限，无法访问所选文件夹')),
      );
      return;
    }
    String? pickedPath;
    try {
      pickedPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择音乐文件夹',
        lockParentWindow: true,
      );
    } catch (_) {
      pickedPath = null;
    }
    if (!mounted) return;
    if (pickedPath == null || pickedPath.isEmpty) return; // 用户取消

    final repo = _repo;
    if (repo.folders.contains(pickedPath)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该文件夹已添加')),
      );
      return;
    }
    await repo.addFolder(pickedPath);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已添加：$pickedPath')),
    );
  }

  /// 快捷添加应用内置目录（无需权限）。
  Future<void> _addAppFolder() async {
    final appFolder = await LocalMusicSettingsRepository.defaultAppFolder();
    if (appFolder == null || !mounted) return;
    final repo = _repo;
    if (repo.folders.contains(appFolder)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('内置目录已添加')),
      );
      return;
    }
    await repo.addFolder(appFolder);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已添加：$appFolder')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(localMusicSettingsRepositoryProvider);
    final folders = repo.folders;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('本地音乐')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          // ---------- 扫描文件夹 ----------
          Row(
            children: [
              Expanded(
                child: Text('扫描文件夹（${folders.length}）',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                tooltip: '前往文件管理器选择文件夹',
                icon: const Icon(Icons.create_new_folder_rounded,
                    color: AppTokens.accent),
                onPressed: _pickAndAddFolder,
              ),
            ],
          ),
          if (folders.isEmpty)
            Card(
              child: ListTile(
                leading: Icon(Icons.folder_off_rounded,
                    color: scheme.onSurface.withValues(alpha: 0.4)),
                title: const Text('尚未添加文件夹'),
                subtitle: Text(
                  '添加音乐文件夹后点击「立即扫描」建立本地曲库',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
            )
          else
            for (final folder in folders)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_rounded,
                      color: AppTokens.accent),
                  title: Text(folder,
                      style: const TextStyle(fontSize: 13)),
                  trailing: IconButton(
                    tooltip: '移除',
                    icon: Icon(Icons.close_rounded,
                        size: 20,
                        color: scheme.onSurface.withValues(alpha: 0.5)),
                    onPressed: () async {
                      await _repo.removeFolder(folder);
                      setState(() {});
                    },
                  ),
                ),
              ),
          const SizedBox(height: 4),
          Center(
            child: TextButton.icon(
              onPressed: _addAppFolder,
              icon: const Icon(Icons.inventory_2_outlined, size: 16),
              label: const Text('添加应用内置目录（无需权限）',
                  style: TextStyle(fontSize: 12)),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppTokens.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            onPressed: _scanning ? null : _scan,
            icon: _scanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.radar_rounded),
            label: Text(_scanning ? '正在扫描…' : '立即扫描'),
          ),
          if (_lastCount != null) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                '上次扫描：$_lastCount 首',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          // ---------- 扫描设置 ----------
          const Text(
              '扫描设置',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Card(
            child: SwitchListTile(
              title: const Text('启动时自动扫描'),
              subtitle: const Text(
                '打开应用时在后台刷新本地曲库',
                style: TextStyle(fontSize: 12),
              ),
              value: repo.autoScanOnStartup,
              activeThumbColor: AppTokens.accent,
              onChanged: (value) async {
                await _repo.setAutoScanOnStartup(value);
                if (mounted) setState(() {});
              },
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '提示：Android 13+ 首次扫描会请求「音乐和音频」权限；'
            '内置目录（应用文档目录）无需权限。',
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }
}
