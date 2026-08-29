import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/source/capabilities.dart';
import '../../core/theme/app_tokens.dart';
import '../library/data/library_providers.dart';
import '../player/player_notifier.dart';
import '../shared/widgets/track_tile.dart';

/// 首页（传统 Material 风格）：标准 AppBar + 列表式最近播放。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _scanning = false;

  Future<void> _scanLocalLibrary() async {
    final local =
        ref
            .read(sourceRegistryProvider)
            .all
            .whereType<LibraryScanCapable>()
            .firstOrNull;
    if (local == null) return;
    setState(() => _scanning = true);
    try {
      local.invalidateScanCache();
      await local.scanLibrary(force: true);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本地音乐扫描完成')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('扫描失败，请检查目录权限')));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(recentHistoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Musaic',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: '设置与账号',
            // push 而非 go：go 会替换导航栈，系统返回会直接退出应用
            onPressed: () => context.push('/settings'),
            icon: const Icon(Icons.settings_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: historyAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data:
            (tracks) =>
                tracks.isEmpty
                    ? _EmptyHome(onScan: _scanLocalLibrary, scanning: _scanning)
                    : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: tracks.length + 1,
                      itemBuilder: (context, index) {
                        // 列表第 0 项：断点续播横幅（有快照时呈现）
                        if (index == 0) return const _ResumeBanner();
                        final track = tracks[index - 1];
                        return TrackTile(track: track, queue: tracks);
                      },
                    ),
      ),
    );
  }
}

/// 断点续播横幅：上次会话中断的曲目（空闲时显示）。
class _ResumeBanner extends ConsumerWidget {
  const _ResumeBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(resumePlaybackProvider);
    final track = snapshot?.track;
    if (snapshot == null || track == null) {
      return const SizedBox.shrink();
    }
    final remaining =
        track.duration == null ? null : track.duration! - snapshot.position;
    final hasRemaining =
        remaining != null && remaining > const Duration(seconds: 5);
    final remainLabel =
        hasRemaining
            ? '${remaining.inMinutes}:${(remaining.inSeconds % 60).toString().padLeft(2, '0')}'
            : null;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(
          Icons.play_circle_outline_rounded,
          color: AppTokens.accent,
          size: 32,
        ),
        title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            '继续上次播放 · ${track.artist}',
            if (remainLabel != null) '剩 $remainLabel',
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
        trailing: IconButton(
          tooltip: '忽略此记录',
          icon: Icon(
            Icons.close_rounded,
            size: 18,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.45),
          ),
          onPressed: () async {
            await ref.read(resumeRepositoryProvider).clear();
            ref.invalidate(resumePlaybackProvider);
          },
        ),
        onTap: () async {
          final ok =
              await ref.read(playerNotifierProvider.notifier).restoreResume();
          if (ok && context.mounted) unawaited(context.push('/player'));
        },
      ),
    );
  }
}

/// 空态：引导扫描本地音乐（传统 Material 排版）。
class _EmptyHome extends StatelessWidget {
  const _EmptyHome({required this.onScan, required this.scanning});

  final VoidCallback onScan;
  final bool scanning;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.library_music_rounded,
            size: 72,
            color: AppTokens.accent.withValues(alpha: 0.7),
          ),
          const SizedBox(height: 16),
          const Text(
            '从一首歌开始你的拼图',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '搜索网易云 / QQ 音乐 / 酷狗歌曲，或扫描本地音乐',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: scanning ? null : onScan,
            icon:
                scanning
                    ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.playlist_add_rounded),
            label: const Text('扫描本地音乐'),
          ),
        ],
      ),
    );
  }
}
