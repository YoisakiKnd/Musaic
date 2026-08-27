import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_tokens.dart';
import '../auth/presentation/channel/account_manage_page.dart';
import '../library/data/backup_service.dart';
import 'local_music_settings_page.dart';
import 'settings_providers.dart';

/// 设置页（一级）：账号管理 / 外观 / 播放与性能 / 数据管理 / 关于，
/// 全部为二级页面入口。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          _EntryCard(
            icon: Icons.library_music_rounded,
            title: '本地音乐',
            subtitle: '扫描文件夹管理 / 启动自动扫描',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const LocalMusicSettingsPage(),
              ),
            ),
          ),
          _EntryCard(
            icon: Icons.person_rounded,
            title: '账号管理',
            subtitle: '网易云 / QQ 音乐 / 酷狗 / YouTube Music 登录与状态',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AccountManagePage(),
              ),
            ),
          ),
          _EntryCard(
            icon: Icons.palette_rounded,
            title: '外观',
            subtitle: '主题模式（跟随系统 / 深色 / 浅色）',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AppearancePage(),
              ),
            ),
          ),
          _EntryCard(
            icon: Icons.tune_rounded,
            title: '播放与性能',
            subtitle: '玻璃模糊效果等',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const PlaybackPage(),
              ),
            ),
          ),
          _EntryCard(
            icon: Icons.storage_rounded,
            title: '数据管理',
            subtitle: '搜索历史 / 播放历史 / 喜欢的音乐',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DataPage(),
              ),
            ),
          ),
          _EntryCard(
            icon: Icons.info_outline_rounded,
            title: '关于',
            subtitle: '版本与免责声明',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AboutPage(),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '凭据仅存于本机安全存储（Keychain / Keystore），永不明文上传',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 二级页：外观。
class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('外观')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: RadioGroup<ThemeMode>(
              groupValue: themeMode,
              onChanged: (value) => ref
                  .read(themeModeProvider.notifier)
                  .set(value ?? ThemeMode.dark),
              child: Column(
                children: [
                  for (final mode in ThemeMode.values)
                    RadioListTile<ThemeMode>(
                      value: mode,
                      title: Text(switch (mode) {
                        ThemeMode.system => '跟随系统',
                        ThemeMode.dark => '深色',
                        ThemeMode.light => '浅色',
                      }),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              title: const Text('OLED 纯黑背景'),
              subtitle: const Text(
                '深色主题下使用纯黑背景，省电且对比更强',
                style: TextStyle(fontSize: 12),
              ),
              value: ref.watch(oledBlackProvider),
              activeThumbColor: AppTokens.accent,
              onChanged: (value) =>
                  ref.read(oledBlackProvider.notifier).set(value),
            ),
          ),
        ],
      ),
    );
  }
}

/// 二级页：播放与性能。
class PlaybackPage extends ConsumerWidget {
  const PlaybackPage({super.key});

  static const _qualityLabels = <AudioQuality, String>{
    AudioQuality.low: '流畅 128k',
    AudioQuality.normal: '标准 192k',
    AudioQuality.high: '高品质 320k',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final glass = ref.watch(enableGlassProvider);
    final quality = ref.watch(audioQualityProvider);
    final offsetMs = ref.watch(lyricOffsetMsProvider);
    final rawTimeout = ref.watch(networkTimeoutSecondsProvider);
    // 恢复值可能不在档位上，归到最近档展示
    final timeoutSeconds = const [8, 14, 20]
        .reduce((a, b) => (a - rawTimeout).abs() <= (b - rawTimeout).abs() ? a : b);
    return Scaffold(
      appBar: AppBar(title: const Text('播放与性能')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---------- 播放音质 ----------
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('播放音质',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  const Text(
                    '下次播放生效；不支持档位切换的渠道按默认码率播放',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<AudioQuality>(
                      segments: [
                        for (final entry in _qualityLabels.entries)
                          ButtonSegment(
                            value: entry.key,
                            label: Text(entry.value),
                          ),
                      ],
                      selected: {quality},
                      onSelectionChanged: (selection) => ref
                          .read(audioQualityProvider.notifier)
                          .set(selection.first),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // ---------- 歌词时间偏移 ----------
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '歌词时间偏移 ${offsetMs > 0 ? '+' : ''}'
                    '${(offsetMs / 1000).toStringAsFixed(1)}s',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Text(
                    '歌词显快调负、显慢调正（±10s）',
                    style: TextStyle(fontSize: 12),
                  ),
                  Slider(
                    value: offsetMs.toDouble().clamp(-10000, 10000),
                    min: -10000,
                    max: 10000,
                    divisions: 100,
                    label: '${(offsetMs / 1000).toStringAsFixed(1)}s',
                    onChanged: (v) => ref
                        .read(lyricOffsetMsProvider.notifier)
                        .set(v.round()),
                  ),
                  if (offsetMs != 0)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () =>
                            ref.read(lyricOffsetMsProvider.notifier).set(0),
                        child: const Text('归零'),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // ---------- 请求超时 ----------
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('网络请求超时',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  const Text(
                    '受限网络 / 代理环境可调大档位，播放与搜索即时生效',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 8, label: Text('标准 8s')),
                        ButtonSegment(value: 14, label: Text('宽松 14s')),
                        ButtonSegment(value: 20, label: Text('弱网 20s')),
                      ],
                      selected: {timeoutSeconds},
                      onSelectionChanged: (selection) => ref
                          .read(networkTimeoutSecondsProvider.notifier)
                          .set(selection.first),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // ---------- 玻璃效果 ----------
          Card(
            child: SwitchListTile(
              title: const Text('玻璃模糊效果'),
              subtitle: const Text(
                '迷你播放条实时模糊；低端设备关闭可提升流畅度',
                style: TextStyle(fontSize: 12),
              ),
              value: glass,
              activeThumbColor: AppTokens.accent,
              onChanged: (value) =>
                  ref.read(enableGlassProvider.notifier).set(value),
            ),
          ),
        ],
      ),
    );
  }
}

/// 二级页：数据管理。
class DataPage extends ConsumerWidget {
  const DataPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('数据管理')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---------- 备份：导出 / 导入 ----------
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('导出资料库（JSON）'),
                  subtitle: const Text(
                    '收藏 / 歌单 / 最近播放 → 备份文件（不含任何渠道凭据）',
                    style: TextStyle(fontSize: 12),
                  ),
                  onTap: () => _exportBackup(context, ref),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.file_upload_outlined),
                  title: const Text('导入资料库（JSON）'),
                  subtitle: const Text(
                    '合并式导入：按曲目去重，不删除本地已有数据',
                    style: TextStyle(fontSize: 12),
                  ),
                  onTap: () => _importBackup(context, ref),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.history_rounded),
                  title: const Text('清除搜索历史'),
                  onTap: () async {
                    final repo = ref.read(searchHistoryRepositoryProvider);
                    await repo.clear();
                    if (!context.mounted) return;
                    _toast(context, '搜索历史已清除');
                  },
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.playlist_remove_rounded),
                  title: const Text('清除播放历史'),
                  onTap: () async {
                    final repo = ref.read(libraryRepositoryProvider);
                    await repo.clearHistory();
                    if (!context.mounted) return;
                    _toast(context, '播放历史已清除');
                  },
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: const Text('清除封面缓存'),
                  subtitle: const Text('删除本地扫描生成的内嵌封面缓存',
                      style: TextStyle(fontSize: 12)),
                  onTap: () async {
                    final cleared = await _clearCoverCache();
                    if (!context.mounted) return;
                    _toast(context, cleared
                        ? '封面缓存已清除'
                        : '暂无需要清理的缓存');
                  },
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.favorite_border_rounded),
                  title: const Text('清空喜欢的音乐'),
                  onTap: () async {
                    final repo = ref.read(libraryRepositoryProvider);
                    for (final track in repo.favorites.toList()) {
                      await repo.toggleFavorite(track);
                    }
                    if (!context.mounted) return;
                    _toast(context, '已清空喜欢的音乐');
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 导出：优先系统保存对话框；不支持/取消时落到文档目录。
  Future<void> _exportBackup(BuildContext context, WidgetRef ref) async {
    final service = ref.read(backupServiceProvider);
    final json = service.snapshot().encodePretty();
    final fileName =
        'musaic-backup-${DateTime.now().toIso8601String().substring(0, 10)}.json';
    try {
      String? savedPath = await FilePicker.platform.saveFile(
        dialogTitle: '导出资料库',
        fileName: fileName,
      );
      if (savedPath == null) {
        // 平台不支持保存对话框或用户取消：尝试静默写入文件
        if (!context.mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('导出资料库'),
            content: const Text(
                '未选择保存位置，将导出到应用文档目录（Musaic/ 下），继续？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('导出'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        final documents = await getApplicationDocumentsDirectory();
        final dir = Directory(p.join(documents.path, 'Musaic'));
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final file = File(p.join(dir.path, fileName));
        await file.writeAsString(json);
        savedPath = file.path;
      } else {
        await File(savedPath).writeAsString(json);
      }
      if (!context.mounted) return;
      _toast(context, '已导出：$savedPath');
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '导出失败：$e');
    }
  }

  /// 导入：选择 JSON 备份并合并。
  Future<void> _importBackup(BuildContext context, WidgetRef ref) async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: '选择 Musaic 备份文件',
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      final fileBytes = picked?.files.single.bytes ??
          (picked?.files.single.path == null
              ? null
              : await File(picked!.files.single.path!).readAsBytes());
      if (fileBytes == null) return;
      final service = ref.read(backupServiceProvider);
      final backup = service.decode(utf8.decode(fileBytes));
      final result = await service.importBackup(backup);
      if (!context.mounted) return;
      _toast(
        context,
        '导入完成：收藏 ${result.favorites} · 歌单 ${result.playlists} · '
        '历史 ${result.history}',
      );
    } on FormatException catch (e) {
      if (!context.mounted) return;
      _toast(context, '文件格式不正确：${e.message}');
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '导入失败：$e');
    }
  }
}

/// 二级页：关于。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.info_outline_rounded),
                  title: Text('Musaic · 音乐拼图'),
                  subtitle: Text('版本 0.1.0 · 多渠道聚合播放器'),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.code_rounded),
                  title: const Text('开源仓库'),
                  subtitle: const Text(
                    'github.com/YoisakiKnd/Musaic',
                    style: TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.copy_rounded, size: 18),
                  onTap: () {
                    Clipboard.setData(
                      const ClipboardData(text: 'https://github.com/YoisakiKnd/Musaic'),
                    );
                    _toast(context, '仓库地址已复制');
                  },
                ),
                const Divider(height: 1, indent: 56),
                const ListTile(
                  leading: Icon(Icons.gavel_rounded),
                  title: Text('免责声明'),
                  subtitle: Text(
                    '仅调用各渠道公开接口，不破解不缓存受限内容；请支持正版',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<bool> _clearCoverCache() async {
  try {
    final temp = await getTemporaryDirectory();
    final dir = Directory(p.join(temp.path, 'musaic_covers'));
    if (!dir.existsSync()) return false;
    await dir.delete(recursive: true);
    return true;
  } catch (_) {
    return false;
  }
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusCard - 4),
        ),
        leading: CircleAvatar(
          backgroundColor: AppTokens.accent.withValues(alpha: 0.15),
          child: Icon(icon, size: 22, color: AppTokens.accent),
        ),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}
