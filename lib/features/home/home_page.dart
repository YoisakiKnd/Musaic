import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_tokens.dart';
import '../../sources/local/local_file_source.dart';
import '../library/data/library_providers.dart';
import '../shared/widgets/track_tile.dart';

/// 首页：问候 + 最近播放（Master Plan P6）。
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
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_greeting),
            Text('Musaic · 音乐拼图',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.5),
                )),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '扫描本地音乐',
            onPressed: _scanning ? null : _scanLocalLibrary,
            icon: _scanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.library_music_rounded),
          ),
        ],
      ),
      body: historyAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data: (history) => history.isEmpty
            ? _EmptyHome(onScan: _scanLocalLibrary)
            : ListView.builder(
                padding: AppTokens.pagePadding,
                itemCount: history.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('最近播放',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    );
                  }
                  final track = history[index - 1];
                  return TrackTile(
                    track: track,
                    queue: history,
                  );
                },
              ),
      ),
    );
  }
}

class _EmptyHome extends StatelessWidget {
  const _EmptyHome({required this.onScan});

  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.graphic_eq_rounded,
              size: 72,
              color: AppTokens.accent.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text('从一首歌开始你的拼图',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('搜索网易云歌曲，或扫描本地音乐',
              style: TextStyle(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.55),
              )),
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppTokens.accent,
            ),
            onPressed: onScan,
            icon: const Icon(Icons.library_music_rounded),
            label: const Text('扫描本地音乐'),
          ),
        ],
      ),
    );
  }
}
