import 'dart:io' show File;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/model/track.dart';
import '../../core/theme/app_tokens.dart';
import '../../sources/local/local_file_source.dart';
import '../library/data/library_providers.dart';
import '../player/player_notifier.dart';

/// 首页（Mei / Apple Music 风格）：搜索胶囊 + 大问候语 + 横滑封面卡。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _scanning = false;

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 6) return '夜深了';
    if (hour < 12) return '早上好';
    if (hour < 18) return '下午好';
    return '晚上好';
  }

  Future<void> _scanLocalLibrary() async {
    final registry = ref.read(sourceRegistryProvider);
    final local =
        registry.resolve(LocalFileSource.id) as LocalFileSource?;
    if (local == null) return;
    setState(() => _scanning = true);
    try {
      local.invalidateScanCache();
      await local.scanLibrary(force: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地音乐扫描完成')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('扫描失败，请检查目录权限')),
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(recentHistoryProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 140),
          children: [
            // ---------- 搜索胶囊 + 设置 ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => context.go('/search'),
                      child: Container(
                        height: 52,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 18),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest
                              .withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(26),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.search_rounded,
                                size: 22,
                                color: AppTokens.darkTextSecondary),
                            SizedBox(width: 10),
                            Text(
                              '搜索',
                              style: TextStyle(
                                fontSize: 16,
                                color: AppTokens.darkTextSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '设置与账号',
                    // push 而非 go：go 会替换导航栈，系统返回会直接退出应用
                    onPressed: () => context.push('/settings'),
                    icon: const Icon(Icons.settings_rounded),
                  ),
                ],
              ),
            ),
            // ---------- 问候语 ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 4),
              child: Text(
                _greeting,
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            // ---------- 最近播放 ----------
            historyAsync.when(
              loading: () => const SizedBox(
                  height: 200,
                  child: Center(child: CircularProgressIndicator())),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(20),
                child: Text('加载失败：$e'),
              ),
              data: (history) => history.isEmpty
                  ? _EmptyHome(onScan: _scanLocalLibrary)
                  : _RecentSection(tracks: history),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentSection extends StatelessWidget {
  const _RecentSection({required this.tracks});

  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Text('最近播放',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        ),
        SizedBox(
          height: 178,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            itemCount: tracks.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, index) =>
                _CoverCard(track: tracks[index], queue: tracks),
          ),
        ),
      ],
    );
  }
}

class _CoverCard extends ConsumerWidget {
  const _CoverCard({required this.track, required this.queue});

  final Track track;
  final List<Track> queue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () {
        ref.read(playerNotifierProvider.notifier).playQueue(
              queue,
              startIndex:
                  queue.indexWhere((t) => t.key == track.key).clamp(
                      0, queue.isEmpty ? 0 : queue.length - 1),
            );
        context.push('/player');
      },
      child: SizedBox(
        width: 132,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 132,
                height: 132,
                child: _Cover(coverUrl: track.coverUrl),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 13),
            ),
            Text(
              track.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.coverUrl});

  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    const Widget fallback = DecoratedBox(
      decoration: BoxDecoration(gradient: AppTokens.brandGradient),
      child: Center(
        child:
            Icon(Icons.music_note_rounded, size: 36, color: Colors.white70),
      ),
    );
    final url = coverUrl;
    if (url == null || url.isEmpty) return fallback;
    if (url.startsWith('file://')) {
      return Image.file(
        File(Uri.parse(url).toFilePath()),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: 264,
      placeholder: (_, _) => const ColoredBox(
        color: AppTokens.darkSurfaceHigh,
        child: SizedBox.expand(),
      ),
      errorWidget: (_, _, _) => fallback,
    );
  }
}

class _EmptyHome extends StatelessWidget {
  const _EmptyHome({required this.onScan});

  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 60),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.graphic_eq_rounded,
              size: 72, color: AppTokens.accent.withValues(alpha: 0.55)),
          const SizedBox(height: 16),
          const Text('从一首歌开始你的拼图',
              style:
                  TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('搜索网易云 / QQ 音乐 / 酷狗歌曲，或扫描本地音乐',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.55),
              )),
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppTokens.accent,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            onPressed: onScan,
            icon: _scanningIcon(),
            label: const Text('扫描本地音乐'),
          ),
        ],
      ),
    );
  }

  Widget _scanningIcon() {
    return Builder(builder: (context) {
      final state = context.findAncestorStateOfType<_HomePageState>();
      return state?._scanning ?? false
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.library_music_rounded);
    });
  }
}
