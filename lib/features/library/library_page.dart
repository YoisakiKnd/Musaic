import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart' show libraryRepositoryProvider;
import '../../core/logging/app_logger.dart';
import '../../core/model/track.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/nav_intent.dart';
import 'playlists_tab.dart';
import '../player/player_notifier.dart';
import '../shared/error_text.dart';
import '../shared/widgets/track_tile.dart';
import 'data/library_providers.dart';
import '../player/open_player.dart';

/// 资料库：歌单 / 喜欢 / 最近播放（Master Plan P6）。
///
/// [initialTabIntent] 是首页快捷入口发起的一次「打开指定 Tab」请求
/// （日常可用性计划 D6）；为 null 即用户点底部 Tab 进入，落在默认的「歌单」。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key, this.initialTabIntent});

  final NavIntent<int>? initialTabIntent;

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage>
    with SingleTickerProviderStateMixin {
  /// Tab 顺序与 TabBar 一致：0 歌单 / 1 喜欢 / 2 最近播放。
  ///
  /// 歌单放第一位：登录后的账号歌单是用户最常找的内容，
  /// 此前排在第三个 Tab，真机上被反馈「登录后看不到歌单」。
  static const int _tabCount = 3;

  late final TabController _tabController;
  int? _consumedSerial;

  @override
  void initState() {
    super.initState();
    // DefaultTabController 的 initialIndex 只在首次构建时生效，
    // 而首页快捷入口可能在页面已存在时再次请求切 Tab（Tab 状态由
    // StatefulShellRoute 保留），因此这里自己持有 controller。
    _tabController = TabController(
      length: _tabCount,
      vsync: this,
      initialIndex: _initialTabIndex(),
    );
    _consumedSerial = widget.initialTabIntent?.serial;
  }

  @override
  void didUpdateWidget(LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final intent = widget.initialTabIntent;
    if (intent == null || intent.serial == _consumedSerial) return;
    _consumedSerial = intent.serial;
    _tabController.animateTo(intent.value.clamp(0, _tabCount - 1));
  }

  int _initialTabIndex() {
    final intent = widget.initialTabIntent;
    if (intent == null) return 0;
    return intent.value.clamp(0, _tabCount - 1);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('资料库'),
        bottom: TabBar(
          // 靠左排列（音乐软件惯例）；Flutter 只允许可滚动的 TabBar 靠左
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          controller: _tabController,
          tabs: const [Tab(text: '歌单'), Tab(text: '喜欢'), Tab(text: '最近播放')],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [PlaylistsTab(), _FavoritesTab(), _HistoryTab()],
      ),
    );
  }
}

class _FavoritesTab extends ConsumerWidget {
  const _FavoritesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favoritesAsync = ref.watch(favoritesProvider);
    return favoritesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error:
          (e, _) =>
              Center(child: Text(loadFailureText(e, tag: 'MusaicLibrary'))),
      data: (favorites) {
        if (favorites.isEmpty) {
          return const _EmptyHint(
            icon: Icons.favorite_border_rounded,
            text: '喜欢的歌曲会出现在这里',
          );
        }
        // 播放全部 + 批量管理（日常可用性计划 D3）：
        // 此前收藏只有单曲 tile，没有「播放全部」，也无法批量整理。
        return _TrackListWithActions(
          tracks: favorites,
          // 收藏页：移除 = 取消收藏。
          onRemoveSelected:
              (keys) =>
                  ref.read(libraryRepositoryProvider).removeFavorites(keys),
          removedLabel: '已取消喜欢',
          onClear: () async {
            await ref.read(libraryRepositoryProvider).clearFavorites();
          },
          clearLabel: '清空喜欢的音乐',
        );
      },
    );
  }
}

class _HistoryTab extends ConsumerWidget {
  const _HistoryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(recentHistoryProvider);
    return historyAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error:
          (e, _) =>
              Center(child: Text(loadFailureText(e, tag: 'MusaicLibrary'))),
      data: (history) {
        if (history.isEmpty) {
          return const _EmptyHint(
            icon: Icons.history_rounded,
            text: '播放过的歌曲会出现在这里',
          );
        }
        // 最近播放同样支持播放全部与批量删除（D3）。
        // 历史无「清空」语义上的歧义，故不提供一键清空入口。
        return _TrackListWithActions(
          tracks: history,
          // 历史页：移除 = 删除历史记录（**不是**取消收藏，U1）。
          onRemoveSelected: (keys) async {
            await ref.read(libraryRepositoryProvider).removeHistory(keys);
          },
          removedLabel: '已从最近播放移除',
        );
      },
    );
  }
}

/// 带「播放全部」与批量管理的曲目列表（日常可用性计划 D3）。
///
/// 收藏与最近播放共用：两者都是「一维曲目列表」，此前只有单曲 tile，
/// 既不能一键播放全部，也无法批量删除。抽成一个组件避免两处重复实现。
class _TrackListWithActions extends ConsumerStatefulWidget {
  const _TrackListWithActions({
    required this.tracks,
    required this.onRemoveSelected,
    required this.removedLabel,
    this.onClear,
    this.clearLabel,
  });

  final List<Track> tracks;

  /// 批量移除所选曲目的回调，由**调用方声明语义**。
  ///
  /// 此前该组件用 `toggleFavorite` 硬编码「移除」，对收藏页恰好等价，
  /// 对历史页则是错的（删不掉历史、反而改写收藏，U1）。
  /// 收藏与历史是两份独立数据，语义必须由 tab 自己给出，
  /// 不能由共用组件猜测。
  final Future<void> Function(Set<String> keys) onRemoveSelected;

  /// 移除成功后的提示词（如「已从最近播放移除」）。
  final String removedLabel;

  /// 一键清空回调；为 null 时不显示该入口。
  final Future<void> Function()? onClear;
  final String? clearLabel;

  @override
  ConsumerState<_TrackListWithActions> createState() =>
      _TrackListWithActionsState();
}

class _TrackListWithActionsState extends ConsumerState<_TrackListWithActions> {
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggle(String key) {
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  Future<void> _removeSelected() async {
    final keys = Set<String>.of(_selected);
    if (keys.isEmpty) return;

    // 计划 3.3：批量移除失败必须给出反馈（此前 await 无 catch）。
    // 失败时选中态与列表都保持原样，用户可重试，不会误以为已移除。
    final messenger = ScaffoldMessenger.of(context);
    try {
      // 语义由调用方提供：收藏页删收藏、历史页删历史（U1）。
      await widget.onRemoveSelected(keys);
      if (!mounted) return;
      _exitSelection();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('${widget.removedLabel} ${keys.length} 首')),
        );
    } catch (e) {
      AppLog.error(
        '批量移除失败：${widget.removedLabel} ${keys.length} 首 | $e',
        tag: 'MusaicLibrary',
      );
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          // 不用 removedLabel 拼失败文案：它是「已取消喜欢」这类完成态措辞，
          // 拼成「已取消喜欢失败」语义别扭。两个调用方的语义都是移除，
          // 统一用中性措辞。
          const SnackBar(content: Text('移除失败，请重试')),
        );
    }
  }

  Future<void> _confirmClear() async {
    final onClear = widget.onClear;
    if (onClear == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(widget.clearLabel ?? '确认清空'),
            content: const Text('该操作不可恢复。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTokens.accent,
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('清空'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    await onClear();
    if (!mounted) return;
    _exitSelection();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${widget.clearLabel ?? '已清空'}完成')));
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.tracks;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTokens.accent,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () {
                  ref.read(playerNotifierProvider.notifier).playQueue(tracks);
                  openPlayerAfterPlay(context);
                },
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: Text('播放全部（${tracks.length}）'),
              ),
              IconButton(
                tooltip: '随机播放',
                onPressed: () {
                  ref.read(playerNotifierProvider.notifier).shufflePlay(tracks);
                  openPlayerAfterPlay(context);
                },
                icon: const Icon(Icons.shuffle_rounded, size: 20),
              ),
              const Spacer(),
              if (_selecting) ...[
                Text(
                  '已选 ${_selected.length}',
                  style: const TextStyle(fontSize: 12),
                ),
                IconButton(
                  tooltip: '移除所选',
                  onPressed: _selected.isEmpty ? null : _removeSelected,
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
                IconButton(
                  tooltip: '取消',
                  onPressed: _exitSelection,
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ] else ...[
                IconButton(
                  tooltip: '批量选择',
                  onPressed: () => setState(() => _selecting = true),
                  icon: const Icon(Icons.checklist_rounded, size: 20),
                ),
                if (widget.onClear != null)
                  IconButton(
                    tooltip: widget.clearLabel ?? '清空',
                    onPressed: _confirmClear,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                  ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: AppTokens.pagePadding,
            itemCount: tracks.length,
            itemBuilder: (context, index) {
              final track = tracks[index];
              final checked = _selected.contains(track.key);
              return TrackTile(
                track: track,
                queue: tracks,
                dense: true,
                onTapOverride: _selecting ? () => _toggle(track.key) : null,
                // 计划 4.3：勾选框用独立回调，不再借道 onTapOverride。
                onCheckboxChanged: _selecting ? () => _toggle(track.key) : null,
                leadingCheckbox: _selecting ? checked : null,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 56, color: AppTokens.accent.withValues(alpha: 0.45)),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}
