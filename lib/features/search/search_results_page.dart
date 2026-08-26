import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/model/track.dart';
import '../../core/theme/app_tokens.dart';
import '../player/player_notifier.dart';
import '../shared/widgets/track_tile.dart';

/// 搜索结果页：支持多选批量操作（加入歌单 / 加入播放队列 / 批量收藏），
/// 以及一键把全部结果存为歌单。
class SearchResultsPage extends ConsumerStatefulWidget {
  const SearchResultsPage({
    super.key,
    required this.query,
    required this.results,
    required this.merged,
  });

  /// 搜索关键词。
  final String query;

  /// 各渠道结果（sourceId → 曲目或错误）。
  final Map<String, Object> results;

  /// 合并后的展示列表（已按提交时的排序处理）。
  final List<Track> merged;

  @override
  ConsumerState<SearchResultsPage> createState() =>
      _SearchResultsPageState();
}

class _SearchResultsPageState extends ConsumerState<SearchResultsPage> {
  final Set<String> _selected = <String>{};
  bool _selecting = false;
  bool _grouped = false;

  late List<Track> _tracks;

  @override
  void initState() {
    super.initState();
    _tracks = widget.merged;
  }

  void _toggleSelect(Track track) {
    setState(() {
      _selected.contains(track.key)
          ? _selected.remove(track.key)
          : _selected.add(track.key);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _enterSelectMode([Track? first]) {
    setState(() {
      _selecting = true;
      if (first != null) _selected.add(first.key);
    });
  }

  void _selectAll() {
    setState(() {
      _selected.addAll(_tracks.map((t) => t.key));
    });
  }

  Future<void> _batchAddToPlaylist() async {
    final tracks =
        _tracks.where((t) => _selected.contains(t.key)).toList();
    if (tracks.isEmpty) return;
    final repository = ref.read(libraryRepositoryProvider);
    final names = repository.playlistNames;
    final target = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '将 ${tracks.length} 首加入歌单',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_circle_outline_rounded,
                  color: AppTokens.accent),
              title: const Text('新建歌单'),
              onTap: () => Navigator.of(sheetContext).pop('__new__'),
            ),
            const Divider(height: 1),
            for (final name in names)
              ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: Text(name),
                onTap: () => Navigator.of(sheetContext).pop(name),
              ),
          ],
        ),
      ),
    );
    if (target == null) return;
    String? name = target;
    if (target == '__new__') {
      if (!mounted) return;
      final controller = TextEditingController();
      name = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('新建歌单'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (value) =>
                Navigator.of(dialogContext).pop(value.trim()),
            decoration: const InputDecoration(hintText: '歌单名称'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: AppTokens.accent),
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('创建'),
            ),
          ],
        ),
      );
        if (name == null || name.isEmpty) return;
      await repository.createPlaylist(name);
    }
    for (final track in tracks) {
      await repository.addToPlaylist(name, track);
    }
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _selecting = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已将 ${tracks.length} 首加入「$name」')),
    );
  }

  void _batchAddToQueue() {
    final tracks =
        _tracks.where((t) => _selected.contains(t.key)).toList();
    final notifier = ref.read(playerNotifierProvider.notifier);
    for (final track in tracks) {
      notifier.addToQueue(track);
    }
    setState(() {
      _selected.clear();
      _selecting = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已将 ${tracks.length} 首加入播放队列')),
    );
  }

  Future<void> _batchFavorite() async {
    final repository = ref.read(libraryRepositoryProvider);
    final tracks =
        _tracks.where((t) => _selected.contains(t.key)).toList();
    for (final track in tracks) {
      final isFav = repository.isFavorite(track.key);
      if (!isFav) await repository.toggleFavorite(track);
    }
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _selecting = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已收藏 ${tracks.length} 首')),
    );
  }

  Future<void> _saveAllAsPlaylist() async {
    if (_tracks.isEmpty) return;
    final repository = ref.read(libraryRepositoryProvider);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('保存全部结果为歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '歌单名称（${_tracks.length} 首）',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTokens.accent),
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await repository.createPlaylist(name);
    for (final track in _tracks) {
      await repository.addToPlaylist(name, track);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已保存「$name」（${_tracks.length} 首）')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) {
          setState(() {
            _selecting = false;
            _selected.clear();
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _selecting
              ? IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => setState(() {
                    _selecting = false;
                    _selected.clear();
                  }),
                )
              : null,
          title: _selecting
              ? Text('已选 ${_selected.length} 首')
              : Text('「${widget.query}」的结果'),
          actions: [
            if (_selecting) ...[
              IconButton(
                tooltip: '全选',
                onPressed: _selectAll,
                icon: const Icon(Icons.select_all_rounded),
              ),
            ] else ...[
              IconButton(
                tooltip: _grouped ? '合并展示' : '分开展示',
                onPressed:
                    _tracks.isEmpty ? null : () => setState(() => _grouped = !_grouped),
                icon: Icon(_grouped
                    ? Icons.view_agenda_outlined
                    : Icons.category_outlined),
              ),
              IconButton(
                tooltip: '多选',
                onPressed: _enterSelectMode,
                icon: const Icon(Icons.checklist_rounded),
              ),
              IconButton(
                tooltip: '全部存为歌单',
                onPressed: _tracks.isEmpty ? null : _saveAllAsPlaylist,
                icon: const Icon(Icons.playlist_add_rounded),
              ),
            ],
          ],
        ),
        body: _tracks.isEmpty
            ? Center(
                child: Text(
                  '没有搜索结果',
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              )
            : _grouped
                ? _buildGroupedBody(scheme)
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(
                      0, 8, 0, _selecting ? 120 : 160,
                    ),
                    itemCount: _tracks.length,
                    itemBuilder: (context, index) {
                      final track = _tracks[index];
                      final checked = _selected.contains(track.key);
                      return Row(
                        children: [
                          if (_selecting)
                            Checkbox(
                              value: checked,
                              activeColor: AppTokens.accent,
                              onChanged: (_) => _toggleSelect(track),
                            ),
                          Expanded(
                            child: TrackTile(
                              key: ValueKey('result-${track.key}-$index'),
                              track: track,
                              queue: _tracks,
                              dense: true,
                              onTapOverride: _selecting
                                  ? () => _toggleSelect(track)
                                  : null,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
        bottomNavigationBar: _selecting
            ? SafeArea(
                minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.97),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _batchAction(
                        Icons.playlist_add_rounded,
                        '加入歌单',
                        _batchAddToPlaylist,
                      ),
                      _batchAction(
                        Icons.queue_music_rounded,
                        '加入队列',
                        _batchAddToQueue,
                      ),
                      _batchAction(
                        Icons.favorite_border_rounded,
                        '收藏',
                        _batchFavorite,
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
    );
  }

  /// 分组模式：按渠道分节展示（含失败渠道的错误提示）。
  Widget _buildGroupedBody(ColorScheme scheme) {
    final registry = ref.read(sourceRegistryProvider);
    final children = <Widget>[];
    for (final source in registry.all) {
      final value = widget.results[source.sourceId];
      if (value is List<Track>) {
        if (value.isEmpty) continue;
        // 分组节标题
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 14,
                decoration: BoxDecoration(
                  color: AppTokens.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                source.displayName,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${value.length} 首',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
        ));
        for (final track in value) {
          final checked = _selected.contains(track.key);
          children.add(Row(
            children: [
              if (_selecting)
                Checkbox(
                  value: checked,
                  activeColor: AppTokens.accent,
                  onChanged: (_) => _toggleSelect(track),
                ),
              Expanded(
                child: TrackTile(
                  key: ValueKey('grouped-${track.key}'),
                  track: track,
                  queue: value,
                  dense: true,
                  onTapOverride:
                      _selecting ? () => _toggleSelect(track) : null,
                ),
              ),
            ],
          ));
        }
      } else if (value is String) {
        // 渠道失败提示
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 16, color: scheme.error.withValues(alpha: 0.7)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '${source.displayName}：$value',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.5),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ));
      }
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(0, 8, 0, _selecting ? 120 : 160),
      children: children,
    );
  }

  Widget _batchAction(
    IconData icon,
    String label,
    VoidCallback onTap,
  ) =>
      InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: AppTokens.accent),
              const SizedBox(height: 4),
              Text(label, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      );
}
