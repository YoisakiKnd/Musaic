import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/app_info.dart';
import '../../core/di/app_providers.dart';
import '../../core/logging/app_logger.dart';
import '../../core/utils/cover_cache.dart';
import '../../core/theme/app_tokens.dart';
import '../auth/presentation/channel/account_manage_page.dart';
import '../library/data/backup_service.dart';
import '../player/domain/crossfade.dart';
import '../shared/error_text.dart';
import '../shared/widgets/confirm_dialog.dart';
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
            onTap:
                () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const LocalMusicSettingsPage(),
                  ),
                ),
          ),
          _EntryCard(
            icon: Icons.person_rounded,
            title: '账号管理',
            subtitle: '网易云 / QQ 音乐 / 酷狗 / YouTube Music 登录与状态',
            onTap:
                () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AccountManagePage(),
                  ),
                ),
          ),
          _EntryCard(
            icon: Icons.palette_rounded,
            title: '外观',
            subtitle: '主题模式（跟随系统 / 深色 / 浅色）',
            onTap:
                () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AppearancePage(),
                  ),
                ),
          ),
          _EntryCard(
            icon: Icons.tune_rounded,
            title: '播放与性能',
            subtitle: '玻璃模糊效果等',
            onTap:
                () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const PlaybackPage()),
                ),
          ),
          _EntryCard(
            icon: Icons.storage_rounded,
            title: '数据管理',
            subtitle: '搜索历史 / 播放历史 / 喜欢的音乐',
            onTap:
                () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const DataPage()),
                ),
          ),
          _EntryCard(
            icon: Icons.info_outline_rounded,
            title: '关于',
            subtitle: '版本与免责声明',
            onTap:
                () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const AboutPage()),
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
              onChanged:
                  (value) => ref
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
              onChanged:
                  (value) => ref.read(oledBlackProvider.notifier).set(value),
            ),
          ),
          const SizedBox(height: 12),
          // ---------- 封面取色 ----------
          Card(
            child: SwitchListTile(
              title: const Text('封面取色动态背景'),
              subtitle: const Text(
                '播放页背景随专辑封面取色；关闭统一使用品牌渐变',
                style: TextStyle(fontSize: 12),
              ),
              value: ref.watch(dynamicCoverColorProvider),
              onChanged:
                  (value) =>
                      ref.read(dynamicCoverColorProvider.notifier).set(value),
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
    final cellularDowngrade = ref.watch(cellularAutoDowngradeProvider);
    final offsetMs = ref.watch(lyricOffsetMsProvider);
    final rawTimeout = ref.watch(networkTimeoutSecondsProvider);
    // 恢复值可能不在档位上，归到最近档展示
    final timeoutSeconds = const [8, 14, 20].reduce(
      (a, b) => (a - rawTimeout).abs() <= (b - rawTimeout).abs() ? a : b,
    );
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
                  const Text(
                    '播放音质',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
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
                      onSelectionChanged:
                          (selection) => ref
                              .read(audioQualityProvider.notifier)
                              .set(selection.first),
                    ),
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text(
                      '蜂窝网络自动降质',
                      style: TextStyle(fontSize: 14),
                    ),
                    subtitle: const Text(
                      '移动流量下自动降低一档音质，减少流量与电量消耗',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: cellularDowngrade,
                    onChanged:
                        (value) => ref
                            .read(cellularAutoDowngradeProvider.notifier)
                            .set(value),
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
                    onChanged:
                        (v) => ref
                            .read(lyricOffsetMsProvider.notifier)
                            .set(v.round()),
                  ),
                  if (offsetMs != 0)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed:
                            () =>
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
                  const Text(
                    '网络请求超时',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
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
                      onSelectionChanged:
                          (selection) => ref
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
              title: const Text('播放页封面模糊背景'),
              subtitle: const Text(
                '开启：封面低分辨率上采样模糊；关闭：取色渐变',
                style: TextStyle(fontSize: 12),
              ),
              value: glass,
              activeThumbColor: AppTokens.accent,
              onChanged:
                  (value) => ref.read(enableGlassProvider.notifier).set(value),
            ),
          ),
          const SizedBox(height: 12),
          // ---------- 启动自动恢复 ----------
          Card(
            child: SwitchListTile(
              title: const Text('启动时自动恢复上次播放'),
              subtitle: const Text(
                '打开应用后自动续播断点曲目（默认关闭）',
                style: TextStyle(fontSize: 12),
              ),
              value: ref.watch(autoResumeOnLaunchProvider),
              onChanged:
                  (value) =>
                      ref.read(autoResumeOnLaunchProvider.notifier).set(value),
            ),
          ),

          // ---------- 交叉淡入 ----------
          const SizedBox(height: 12),
          _CrossfadeCard(),
        ],
      ),
    );
  }
}

/// 交叉淡入设置（N4）。
///
/// 默认关闭：交叉淡入需要**两路音频同时解码**（双播放器），
/// 在低端机上是实打实的额外开销；且它会改变「曲末听感」，
/// 不适合替用户默认开启。
class _CrossfadeCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seconds = ref.watch(crossfadeSecondsProvider);
    final enabled = seconds > 0;
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('交叉淡入淡出'),
            subtitle: const Text(
              '曲末与下一首重叠渐变，消除曲间停顿（默认关闭）',
              style: TextStyle(fontSize: 12),
            ),
            value: enabled,
            onChanged:
                (value) => ref
                    .read(crossfadeSecondsProvider.notifier)
                    // 开启时用默认 4 秒；关闭置 0
                    .set(value ? Crossfade.defaultDuration.inSeconds : 0),
          ),
          if (enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  const Text('时长', style: TextStyle(fontSize: 13)),
                  Expanded(
                    child: Slider(
                      value: seconds.toDouble(),
                      min: 1,
                      max: maxCrossfadeSeconds.toDouble(),
                      divisions: maxCrossfadeSeconds - 1,
                      label: '$seconds 秒',
                      onChanged:
                          (value) => ref
                              .read(crossfadeSecondsProvider.notifier)
                              .set(value.round()),
                    ),
                  ),
                  Text('$seconds 秒', style: const TextStyle(fontSize: 13)),
                ],
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
                    // 不可恢复：先确认再执行（用户层交互计划 2.1）
                    final confirmed = await confirmDestructiveAction(
                      context,
                      title: '清除搜索历史？',
                      message: '将删除全部历史搜索记录，该操作不可恢复。',
                    );
                    if (!confirmed || !context.mounted) return;
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
                    // 不可恢复：先确认再执行（用户层交互计划 2.1）
                    final confirmed = await confirmDestructiveAction(
                      context,
                      title: '清除播放历史？',
                      message: '将删除「最近播放」的全部记录，该操作不可恢复。',
                    );
                    if (!confirmed || !context.mounted) return;
                    final repo = ref.read(libraryRepositoryProvider);
                    await repo.clearHistory();
                    if (!context.mounted) return;
                    _toast(context, '播放历史已清除');
                  },
                ),
                const Divider(height: 1, indent: 56),
                FutureBuilder<int>(
                  future: coverCacheBytes(),
                  builder: (context, snapshot) {
                    final bytes = snapshot.data;
                    final sizeText =
                        bytes == null
                            ? '正在统计…'
                            : bytes == 0
                            ? '暂无缓存'
                            : '当前占用 ${formatBytes(bytes)}';
                    return ListTile(
                      leading: const Icon(Icons.image_outlined),
                      title: const Text('清除封面缓存'),
                      subtitle: Text(
                        '本地扫描生成的内嵌封面；$sizeText',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onTap: () async {
                        // 缓存可重建，但重扫代价高：同样先确认（计划 2.1）
                        final confirmed = await confirmDestructiveAction(
                          context,
                          title: '清除封面缓存？',
                          message:
                              '将删除本地扫描生成的封面缓存；'
                              '下次浏览时需重新生成，不影响曲库与歌单。',
                          confirmLabel: '清除',
                        );
                        if (!confirmed || !context.mounted) return;
                        final cleared = await clearCoverCache();
                        if (!context.mounted) return;
                        _toast(context, cleared ? '封面缓存已清除' : '暂无需要清理的缓存');
                      },
                    );
                  },
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.bug_report_outlined),
                  title: const Text('导出诊断日志'),
                  subtitle: const Text(
                    '最近 500 条运行日志（已脱敏，不含凭据）',
                    style: TextStyle(fontSize: 12),
                  ),
                  onTap: () => _exportDiagnostics(context),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.favorite_border_rounded),
                  title: const Text('清空喜欢的音乐'),
                  onTap: () async {
                    // 收藏是用户手工积累的数据，误清空无法恢复（计划 2.1）
                    final confirmed = await confirmDestructiveAction(
                      context,
                      title: '清空喜欢的音乐？',
                      message: '将移除全部已收藏曲目，该操作不可恢复。',
                    );
                    if (!confirmed || !context.mounted) return;
                    final repo = ref.read(libraryRepositoryProvider);
                    // 仓库级批量清空：一次 Hive clear()，替代逐条 toggleFavorite
                    // 的 N 次往返（P2）。
                    await repo.clearFavorites();
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
  ///
  /// 编码移出主 isolate（大曲库下同步 encodePretty 会卡帧），
  /// 落盘走「临时文件 + rename」原子替换，避免中途崩溃截断用户文件。
  Future<void> _exportBackup(BuildContext context, WidgetRef ref) async {
    final service = ref.read(backupServiceProvider);
    final backup = service.snapshot();
    final fileName =
        'musaic-backup-${DateTime.now().toIso8601String().substring(0, 10)}.json';
    try {
      final json = await Isolate.run(backup.encodePretty);
      String? savedPath = await FilePicker.platform.saveFile(
        dialogTitle: '导出资料库',
        fileName: fileName,
      );
      if (savedPath == null) {
        // 平台不支持保存对话框或用户取消：尝试静默写入文件
        if (!context.mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder:
              (dialogContext) => AlertDialog(
                title: const Text('导出资料库'),
                content: const Text('未选择保存位置，将导出到应用文档目录（Musaic/ 下），继续？'),
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
        await _writeAtomically(file, json);
        savedPath = file.path;
      } else {
        await _writeAtomically(File(savedPath), json);
      }
      if (!context.mounted) return;
      _toast(context, '已导出：$savedPath');
    } catch (e) {
      if (!context.mounted) return;
      _toast(
        context,
        loadFailureText(e, tag: 'MusaicSettings', prefix: '导出失败'),
      );
    }
  }

  /// 原子写：同目录写临时文件后 rename 覆盖目标。
  ///
  /// 直接 `writeAsString` 会先截断目标文件，磁盘满或进程被杀时
  /// 用户原有的备份文件即被破坏（P1 回归）。
  static Future<void> _writeAtomically(File target, String contents) async {
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(contents, flush: true);
    await temp.rename(target.path);
  }

  /// 导出诊断日志（迭代计划 H21 / B27）。
  ///
  /// 日志在写入环形缓冲前已强制脱敏（见 `core/logging/app_logger.dart`），
  /// 因此可以直接交给用户粘贴到 issue。
  Future<void> _exportDiagnostics(BuildContext context) async {
    final text = AppLog.exportText();
    if (text.isEmpty) {
      _toast(context, '暂无日志可导出');
      return;
    }
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .substring(0, 19);
    final fileName = 'musaic-diagnostics-$stamp.txt';
    try {
      final documents = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(documents.path, 'Musaic'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File(p.join(dir.path, fileName));
      await _writeAtomically(file, text);
      if (!context.mounted) return;
      _toast(context, '诊断日志已导出：${file.path}');
    } catch (e) {
      if (!context.mounted) return;
      _toast(
        context,
        loadFailureText(e, tag: 'MusaicSettings', prefix: '导出失败'),
      );
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
      final fileBytes =
          picked?.files.single.bytes ??
          (picked?.files.single.path == null
              ? null
              : await File(picked!.files.single.path!).readAsBytes());
      if (fileBytes == null) return;
      final service = ref.read(backupServiceProvider);
      final backup = service.decodeBytes(fileBytes);
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
      _toast(
        context,
        loadFailureText(e, tag: 'MusaicSettings', prefix: '导入失败'),
      );
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
                  title: Text(AppInfo.appName),
                  subtitle: Text('版本 ${AppInfo.version} · 多渠道聚合播放器'),
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
                      const ClipboardData(text: AppInfo.repositoryUrl),
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
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
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
