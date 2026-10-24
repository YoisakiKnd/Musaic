import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/source/capabilities.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/nav_intent.dart';
import '../auth/presentation/channel/account_manage_page.dart';
import '../library/data/library_providers.dart';
import '../library/data/remote_playlists_provider.dart';
import '../library/playlist_detail_page.dart';
import '../library/playlists_tab.dart';
import '../library/widgets/playlist_card.dart';
import '../player/player_notifier.dart';
import '../shared/error_text.dart';
import '../shared/widgets/track_cover.dart';
import '../shared/widgets/track_tile.dart';
import '../player/open_player.dart';

/// 资料库 Tab 索引（与 `LibraryPage` 的 TabBar 顺序一致）。
enum LibraryTab { playlists, favorites, history }

/// 首页：继续收听 / 我喜欢 / 我的歌单 / 最近播放。
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
        toolbarHeight: 64,
        title: Text(
          _greeting(DateTime.now()),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        actions: [
          // 平板 / 桌面的导航栏轨和侧边栏里已有「设置」
          if (MediaQuery.sizeOf(context).width < AppTokens.mediumBreakpoint)
            IconButton(
              tooltip: '设置与账号',
              // push 而非 go：go 会替换导航栈，系统返回会直接退出应用
              onPressed: () => context.push('/settings'),
              icon: const Icon(Icons.settings_outlined),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: historyAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:
            (e, _) =>
                Center(child: Text(loadFailureText(e, tag: 'MusaicHome'))),
        data: (tracks) {
          // 首页 = 继续收听 + 我喜欢 + 我的歌单 + 最近播放。
          // 此前只有三个写着数字的方块和一串历史，登录后的账号歌单
          // 完全不出现在首页（真机反馈「登录之后也没有看到歌单」）。
          final recent = tracks.take(_recentLimit).toList(growable: false);
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              const _ResumeCard(),
              const _FavoritesBanner(),
              const _HomePlaylistsSection(),
              if (tracks.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 56),
                  child: _EmptyHome(
                    onScan: _scanLocalLibrary,
                    scanning: _scanning,
                  ),
                )
              else ...[
                _HomeSectionHeader(
                  title: '最近播放',
                  onMore: () => openLibraryTab(context, LibraryTab.history),
                ),
                for (final track in recent)
                  TrackTile(track: track, queue: tracks),
              ],
            ],
          );
        },
      ),
    );
  }

  static String _greeting(DateTime now) => switch (now.hour) {
    >= 5 && < 11 => '早上好',
    >= 11 && < 13 => '中午好',
    >= 13 && < 18 => '下午好',
    _ => '晚上好',
  };

  /// 首页只露出最近 [_recentLimit] 首，完整列表在资料库。
  static const int _recentLimit = 8;
}

/// 切到资料库分支并指定 Tab。
///
/// 用 [NavIntent] 携带索引，保证「先点歌单、再点歌单」这类重复点击也能生效。
void openLibraryTab(BuildContext context, LibraryTab tab) {
  context.go('/library', extra: NavIntent<int>(tab.index));
}

/// 首页分区标题：左侧标题，右侧「全部」。
class _HomeSectionHeader extends StatelessWidget {
  const _HomeSectionHeader({required this.title, this.onMore});

  final String title;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ),
          if (onMore != null)
            TextButton(
              onPressed: onMore,
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [Text('全部'), Icon(Icons.chevron_right_rounded)],
              ),
            ),
        ],
      ),
    );
  }
}

/// 「我喜欢的音乐」横幅：点击进收藏列表，右侧按钮直接播放全部。
class _FavoritesBanner extends ConsumerWidget {
  const _FavoritesBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(favoritesProvider).valueOrNull;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openLibraryTab(context, LibraryTab.favorites),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: AppTokens.brandGradient,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.favorite_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '我喜欢的音乐',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // 数据未就绪时不写 0：0 是「确实没有」的结论
                      favorites == null
                          ? '—'
                          : favorites.isEmpty
                          ? '点歌曲旁的 ♡ 收藏'
                          : '${favorites.length} 首',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
              ),
              if (favorites != null && favorites.isNotEmpty)
                IconButton.filled(
                  tooltip: '播放全部喜欢',
                  style: IconButton.styleFrom(
                    backgroundColor: AppTokens.accent,
                    foregroundColor: Colors.white,
                  ),
                  onPressed:
                      () => ref
                          .read(playerNotifierProvider.notifier)
                          .playQueue(favorites),
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「我的歌单」横滑：各渠道账号歌单 + 本地歌单。
///
/// 只汇总**账号本人**的歌单（[RemotePlaylistCapable.remotePlaylistsArePersonal]），
/// 推荐歌单留在资料库里单独成节。没有登录任何可同步渠道时，
/// 末尾放一张「同步账号歌单」卡引导登录。
class _HomePlaylistsSection extends ConsumerWidget {
  const _HomePlaylistsSection();

  static const double _cardWidth = 128;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(sourceRegistryProvider).all;
    final cards = <Widget>[];
    final failed = <String>[];
    var loading = false;
    var hasPersonalSource = false;
    var anyLoggedIn = false;

    for (final source in sources) {
      if (source is! RemotePlaylistCapable) continue;
      final personal =
          (source as RemotePlaylistCapable).remotePlaylistsArePersonal;
      if (!personal) continue;
      hasPersonalSource = true;
      if (ref.watch(remotePlaylistCapableProvider(source.sourceId)) == null) {
        continue;
      }
      anyLoggedIn = true;
      final async = ref.watch(remotePlaylistsProvider(source.sourceId));
      switch (async) {
        case AsyncData(:final value):
          for (final playlist in value) {
            cards.add(
              RemotePlaylistCard(playlist: playlist, badge: source.displayName),
            );
          }
        case AsyncError():
          failed.add(source.sourceId);
        default:
          loading = true;
      }
    }

    final localNames = ref.watch(playlistsProvider).valueOrNull ?? const [];
    for (final name in localNames) {
      cards.add(
        LocalPlaylistCard(
          name: name,
          // 在首页分支内打开：底部导航停留在「首页」，返回回到首页
          onOpen:
              () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlaylistDetailPage(name: name),
                ),
              ),
        ),
      );
    }
    if (hasPersonalSource && !anyLoggedIn) {
      cards.add(
        PlaylistActionCard(
          icon: Icons.cloud_sync_rounded,
          title: '同步账号歌单',
          subtitle: '登录网易云 / QQ 音乐',
          onTap: () => AccountManagePage.open(context),
        ),
      );
    }
    if (cards.isEmpty && !loading && failed.isEmpty) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HomeSectionHeader(
          title: '我的歌单',
          onMore: () => openLibraryTab(context, LibraryTab.playlists),
        ),
        if (failed.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '部分账号歌单加载失败',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    for (final id in failed) {
                      ref.invalidate(remotePlaylistsProvider(id));
                    }
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        if (cards.isEmpty && loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (cards.isNotEmpty)
          SizedBox(
            height: _cardWidth + 50 * MediaQuery.textScalerOf(context).scale(1),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: cards.length,
              separatorBuilder: (_, _) => const SizedBox(width: 4),
              itemBuilder:
                  (context, index) =>
                      SizedBox(width: _cardWidth, child: cards[index]),
            ),
          ),
      ],
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
    if (ok && context.mounted) unawaited(openPlayerAfterPlay(context));
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              '同时搜索网易云、QQ 音乐、酷狗与 YouTube Music，或扫描本地音乐',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // 搜索是绝大多数新用户的第一步：作为主按钮；
          // 此前只有「扫描本地音乐」一个按钮，文案却在说「搜索…」。
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () => context.go('/search'),
                icon: const Icon(Icons.search_rounded),
                label: const Text('去搜索'),
              ),
              OutlinedButton.icon(
                onPressed: scanning ? null : onScan,
                icon:
                    scanning
                        ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.folder_open_rounded),
                label: const Text('扫描本地音乐'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
