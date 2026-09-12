import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/source/capabilities.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/nav_intent.dart';
import '../library/data/library_providers.dart';
import '../player/player_notifier.dart';
import '../shared/widgets/track_cover.dart';
import '../shared/widgets/track_tile.dart';

/// 资料库 Tab 索引（与 `LibraryPage` 的 TabBar 顺序一致）。
enum LibraryTab { favorites, history, playlists }

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
        data: (tracks) {
          // 头部两项常驻（继续收听卡无快照时自身收成零尺寸 + 快捷入口），
          // 下方交给 Expanded：空态仍能像以前一样垂直居中，
          // 有历史时列表继续走 builder 按需构建（最近播放上限 50 条）。
          return Column(
            children: [
              const _ResumeCard(),
              const _QuickEntries(),
              Expanded(
                child:
                    tracks.isEmpty
                        ? _EmptyHome(
                          onScan: _scanLocalLibrary,
                          scanning: _scanning,
                        )
                        : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 24),
                          itemCount: tracks.length,
                          itemBuilder:
                              (context, index) => TrackTile(
                                track: tracks[index],
                                queue: tracks,
                              ),
                        ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 「继续收听」大卡：上次会话中断的曲目（日常可用性计划 D6）。
///
/// 无快照时返回零尺寸——**不留空占位**：首页打开第一眼看到的应该是内容，
/// 而不是一张写着「暂无」的卡。数据源是已有的 [resumePlaybackProvider]，
/// 不新增任何网络请求。
class _ResumeCard extends ConsumerWidget {
  const _ResumeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(resumePlaybackProvider);
    final track = snapshot?.track;
    if (snapshot == null || track == null) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final remaining =
        track.duration == null ? null : track.duration! - snapshot.position;
    final hasRemaining =
        remaining != null && remaining > const Duration(seconds: 5);
    final remainLabel =
        hasRemaining
            ? '${remaining.inMinutes}:${(remaining.inSeconds % 60).toString().padLeft(2, '0')}'
            : null;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
        child: Row(
          children: [
            TrackCover(coverUrl: track.coverUrl, size: 64, radius: 14),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '继续收听',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: AppTokens.accent,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      track.artist,
                      if (remainLabel != null) '剩 $remainLabel',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTokens.accent,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _resume(context, ref),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('继续播放'),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '忽略此记录',
              icon: Icon(
                Icons.close_rounded,
                size: 18,
                color: scheme.onSurface.withValues(alpha: 0.45),
              ),
              onPressed: () async {
                await ref.read(resumeRepositoryProvider).clear();
                ref.invalidate(resumePlaybackProvider);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 恢复上次队列并进入播放页。
  ///
  /// 跨 await 后用 context 必须先判 `mounted`（`use_build_context_synchronously`）。
  Future<void> _resume(BuildContext context, WidgetRef ref) async {
    final ok = await ref.read(playerNotifierProvider.notifier).restoreResume();
    if (ok && context.mounted) unawaited(context.push('/player'));
  }
}

/// 快捷入口行：喜欢 / 最近播放 / 歌单（日常可用性计划 D6）。
///
/// 数量直接取自本地资料库的既有 Provider（[favoritesProvider] /
/// [recentHistoryProvider] / [playlistsProvider]），不触发网络请求。
/// 点击经 `go('/library', extra: ...)` 切到资料库分支并指定 Tab——
/// 用 [NavIntent] 携带索引，保证「先点歌单、再点歌单」这类重复点击也能生效。
class _QuickEntries extends ConsumerWidget {
  const _QuickEntries();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(favoritesProvider).valueOrNull;
    final history = ref.watch(recentHistoryProvider).valueOrNull;
    final playlists = ref.watch(playlistsProvider).valueOrNull;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          _QuickEntry(
            icon: Icons.favorite_rounded,
            label: '喜欢',
            // 数据未就绪时显示占位符而不是 0：0 是「确实没有」的确定结论，
            // 加载中显示 0 会让用户以为收藏丢了
            count: favorites?.length,
            onTap: () => _openTab(context, LibraryTab.favorites),
          ),
          const SizedBox(width: 10),
          _QuickEntry(
            icon: Icons.queue_music_rounded,
            label: '歌单',
            count: playlists?.length,
            onTap: () => _openTab(context, LibraryTab.playlists),
          ),
          const SizedBox(width: 10),
          _QuickEntry(
            icon: Icons.history_rounded,
            label: '最近播放',
            count: history?.length,
            onTap: () => _openTab(context, LibraryTab.history),
          ),
        ],
      ),
    );
  }

  void _openTab(BuildContext context, LibraryTab tab) {
    context.go('/library', extra: NavIntent<int>(tab.index));
  }
}

/// 单个快捷入口（图标 + 名称 + 数量）。
class _QuickEntry extends StatelessWidget {
  const _QuickEntry({
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final String label;

  /// null = 数据尚未就绪（显示「—」而非 0）。
  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: AppTokens.accent),
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  count == null ? '—' : '$count',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        ),
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
