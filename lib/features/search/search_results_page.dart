import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/error/source_exception.dart';
import '../../core/network/network_config.dart';
import '../../core/model/track.dart';
import '../../core/theme/app_tokens.dart';
import '../player/player_notifier.dart';
import '../shared/widgets/track_tile.dart';

/// 结果排序模式（聚合搜索可用；相关度保持渠道返回顺序）。
enum SearchSortMode { relevance, durationAsc, durationDesc }

/// 搜索结果页：支持增量流式展示（先到先展示）、渠道失败独立重试、
/// 多选批量操作（加入歌单 / 加入播放队列 / 批量收藏），
/// 以及一键把全部结果存为歌单。
class SearchResultsPage extends ConsumerStatefulWidget {
  const SearchResultsPage({
    super.key,
    required this.query,
    required this.results,
    required this.merged,
    this.pendingSources = const <String>[],
    this.sortMode = SearchSortMode.relevance,
  });

  /// 搜索关键词。
  final String query;

  /// 已完成的各渠道结果（sourceId → 曲目或错误 String）。
  final Map<String, Object> results;

  /// 已完成的合并展示列表。
  final List<Track> merged;

  /// 尚未返回的渠道：页面挂载后自行发起搜索，先到先展示（迭代计划 §10.6）。
  final List<String> pendingSources;

  /// 合并视图排序模式。
  final SearchSortMode sortMode;

  @override
  ConsumerState<SearchResultsPage> createState() => _SearchResultsPageState();
}

class _SearchResultsPageState extends ConsumerState<SearchResultsPage> {
  final Set<String> _selected = <String>{};
  bool _selecting = false;
  bool _grouped = false;

  static const int _pageSize = 20;

  /// 可变结果集（sourceId → List<Track> 或错误 String），分页追加。
  late Map<String, Object> _results;
  late List<Track> _tracks;

  /// 未完成首屏搜索的渠道 / 已到底 / 正在加载的渠道。
  final Set<String> _pending = <String>{};
  final Set<String> _exhausted = <String>{};
  final Set<String> _loadingMore = <String>{};
  final Map<String, String> _loadErrors = <String, String>{};

  @override
  void initState() {
    super.initState();
    _tracks = widget.merged;
    _results = Map<String, Object>.of(widget.results);
    _pending.addAll(widget.pendingSources);
    for (final entry in _results.entries) {
      final v = entry.value;
      if (v is List<Track> && v.length < _pageSize) {
        _exhausted.add(entry.key);
      }
    }
    for (final sourceId in widget.pendingSources) {
      unawaited(_runInitialSearch(sourceId));
    }
  }

  /// 单渠道首屏搜索：返回即上屏（迭代计划 §10.6 先到先展示）。
  Future<void> _runInitialSearch(String sourceId) async {
    final source = ref.read(sourceRegistryProvider).resolve(sourceId);
    if (source == null) {
      _finishPending(sourceId, '渠道未注册');
      return;
    }
    try {
      final tracks = await source
          .search(widget.query, limit: _pageSize)
          .timeout(Duration(seconds: NetworkConfig.instance.seconds + 4));
      if (!mounted) return;
      setState(() {
        _pending.remove(sourceId);
        _results[sourceId] = tracks;
        if (tracks.length < _pageSize) _exhausted.add(sourceId);
        _tracks = _rebuildMerged();
      });
    } on SourceException catch (e) {
      _finishPending(sourceId, e.message);
    } on TimeoutException {
      _finishPending(sourceId, '响应超时');
    } catch (e) {
      debugPrint('MusaicSearch[$sourceId] 异常: $e');
      _finishPending(sourceId, '搜索失败');
    }
  }

  void _finishPending(String sourceId, String message) {
    if (!mounted) return;
    setState(() {
      _pending.remove(sourceId);
      _results[sourceId] = message;
      _tracks = _rebuildMerged();
    });
  }

  /// 渠道失败后重试首屏搜索。
  Future<void> _retrySource(String sourceId) async {
    if (_results[sourceId] is List<Track> || _pending.contains(sourceId)) {
      return;
    }
    setState(() => _pending.add(sourceId));
    await _runInitialSearch(sourceId);
  }

  /// 拉取指定渠道下一页并追加；merged 视图同步重建。
  Future<void> _loadMore(String sourceId) async {
    if (_loadingMore.contains(sourceId) || _exhausted.contains(sourceId)) {
      return;
    }
    final source = ref.read(sourceRegistryProvider).resolve(sourceId);
    final current = _results[sourceId];
    if (source == null || current is! List<Track>) return;
    setState(() => _loadingMore.add(sourceId));
    try {
      final next = await source
          .search(widget.query, limit: _pageSize, offset: current.length)
          .timeout(Duration(seconds: NetworkConfig.instance.seconds + 4));
      if (!mounted) return;
      setState(() {
        _loadErrors.remove(sourceId);
        if (next.length < _pageSize) _exhausted.add(sourceId);
        _results[sourceId] = <Track>[...current, ...next];
        _tracks = _rebuildMerged();
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loadErrors[sourceId] = '加载失败，点击重试');
      }
    } finally {
      if (mounted) setState(() => _loadingMore.remove(sourceId));
    }
  }

  List<Track> _rebuildMerged() {
    final registry = ref.read(sourceRegistryProvider);
    final merged = <Track>[];
    for (final source in registry.all) {
      final value = _results[source.sourceId];
      if (value is List<Track>) merged.addAll(value);
    }
    return _applySort(merged);
  }

  List<Track> _applySort(List<Track> input) {
    switch (widget.sortMode) {
      case SearchSortMode.relevance:
        return input;
      case SearchSortMode.durationAsc:
        return [...input]..sort(
          (a, b) => (a.duration ?? const Duration(days: 1)).compareTo(
            b.duration ?? const Duration(days: 1),
          ),
        );
      case SearchSortMode.durationDesc:
        return [...input]..sort(
          (a, b) => (b.duration ?? Duration.zero).compareTo(
            a.duration ?? Duration.zero,
          ),
        );
    }
  }

  bool get _anySourceHasMore {
    for (final key in _results.keys) {
      if (_results[key] is List<Track> && !_exhausted.contains(key)) {
        return true;
      }
    }
    return false;
  }

  /// 分页页脚按钮。
  Widget _loadMoreTile(String sourceId, ColorScheme scheme) {
    final loading = _loadingMore.contains(sourceId);
    final error = _loadErrors[sourceId];
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child:
            loading
                ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : TextButton.icon(
                  onPressed: () => _loadMore(sourceId),
                  icon: Icon(
                    error == null
                        ? Icons.expand_more_rounded
                        : Icons.refresh_rounded,
                    size: 18,
                  ),
                  label: Text(error ?? '加载更多'),
                ),
      ),
    );
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
    final tracks = _tracks.where((t) => _selected.contains(t.key)).toList();
    if (tracks.isEmpty) return;
    final repository = ref.read(libraryRepositoryProvider);
    final names = repository.playlistNames;
    final target = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder:
          (sheetContext) => SafeArea(
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
                  leading: const Icon(
                    Icons.add_circle_outline_rounded,
                    color: AppTokens.accent,
                  ),
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
        builder:
            (dialogContext) => AlertDialog(
              title: const Text('新建歌单'),
              content: TextField(
                controller: controller,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted:
                    (value) => Navigator.of(dialogContext).pop(value.trim()),
                decoration: const InputDecoration(hintText: '歌单名称'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTokens.accent,
                  ),
                  onPressed:
                      () => Navigator.of(
                        dialogContext,
                      ).pop(controller.text.trim()),
                  child: const Text('创建'),
                ),
              ],
            ),
      );
      if (name == null || name.isEmpty) return;
      await repository.createPlaylist(name);
    }
    await repository.addManyToPlaylist(name, tracks);
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _selecting = false;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已将 ${tracks.length} 首加入「$name」')));
  }

  void _batchAddToQueue() {
    final tracks = _tracks.where((t) => _selected.contains(t.key)).toList();
    final notifier = ref.read(playerNotifierProvider.notifier);
    for (final track in tracks) {
      notifier.addToQueue(track);
    }
    setState(() {
      _selected.clear();
      _selecting = false;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已将 ${tracks.length} 首加入播放队列')));
  }

  Future<void> _batchFavorite() async {
    final repository = ref.read(libraryRepositoryProvider);
    final tracks = _tracks.where((t) => _selected.contains(t.key)).toList();
    for (final track in tracks) {
      final isFav = repository.isFavorite(track.key);
      if (!isFav) await repository.toggleFavorite(track);
    }
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _selecting = false;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已收藏 ${tracks.length} 首')));
  }

  Future<void> _saveAllAsPlaylist() async {
    if (_tracks.isEmpty) return;
    final repository = ref.read(libraryRepositoryProvider);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
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
                style: FilledButton.styleFrom(
                  backgroundColor: AppTokens.accent,
                ),
                onPressed:
                    () =>
                        Navigator.of(dialogContext).pop(controller.text.trim()),
                child: const Text('保存'),
              ),
            ],
          ),
    );
    if (name == null || name.isEmpty) return;
    await repository.createPlaylist(name);
    await repository.addManyToPlaylist(name, _tracks);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已保存「$name」（${_tracks.length} 首）')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasErrors = _results.values.any((v) => v is String);
    final hasAnyContent =
        _tracks.isNotEmpty || _pending.isNotEmpty || hasErrors;
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
          leading:
              _selecting
                  ? IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed:
                        () => setState(() {
                          _selecting = false;
                          _selected.clear();
                        }),
                  )
                  : null,
          title:
              _selecting
                  ? Text('已选 ${_selected.length} 首')
                  : Text('「${widget.query}」的结果'),
          actions: [
            if (_pending.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
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
                    hasAnyContent
                        ? () => setState(() => _grouped = !_grouped)
                        : null,
                icon: Icon(
                  _grouped
                      ? Icons.view_agenda_outlined
                      : Icons.category_outlined,
                ),
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
        body: switch ((hasAnyContent, _tracks.isEmpty, _grouped)) {
          // 无任何结果与渠道信息
          (false, _, _) => Center(
            child: Text(
              '没有搜索结果',
              style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.5)),
            ),
          ),
          // 首屏仍在等待全部渠道
          (true, true, _) when _pending.isNotEmpty => const Center(
            child: CircularProgressIndicator(),
          ),
          // 有曲目走列表；全部失败/搜索中即使未开分组也走分组视图，
          // 保证错误提示与重试入口始终可见
          (true, _, true) => _buildGroupedBody(scheme),
          (true, true, false) => _buildGroupedBody(scheme),
          (true, false, false) => ListView.builder(
            padding: EdgeInsets.fromLTRB(0, 8, 0, _selecting ? 120 : 160),
            itemCount:
                _tracks.length +
                (_pending.isNotEmpty ? 1 : 0) +
                (_anySourceHasMore ? 1 : 0),
            itemBuilder: (context, index) {
              // 搜索中的渠道计数
              if (index == _tracks.length && _pending.isNotEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '正在搜索 ${_pending.length} 个渠道…',
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              // 末尾全局「加载更多」：为所有未穷尽渠道各取一页
              if (index == _tracks.length + (_pending.isNotEmpty ? 1 : 0)) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child:
                        _loadingMore.isEmpty
                            ? TextButton.icon(
                              onPressed: () {
                                for (final key in _results.keys.toList()) {
                                  _loadMore(key);
                                }
                              },
                              icon: const Icon(
                                Icons.expand_more_rounded,
                                size: 18,
                              ),
                              label: const Text('加载更多（各渠道）'),
                            )
                            : const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                  ),
                );
              }
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
                      onTapOverride:
                          _selecting ? () => _toggleSelect(track) : null,
                    ),
                  ),
                ],
              );
            },
          ),
        },
        bottomNavigationBar:
            _selecting
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

  /// 分组模式：按渠道分节展示（搜索中 / 失败重试 / 各渠道分页页脚）。
  Widget _buildGroupedBody(ColorScheme scheme) {
    final registry = ref.read(sourceRegistryProvider);
    final children = <Widget>[];
    for (final source in registry.all) {
      final sourceId = source.sourceId;
      final value = _results[sourceId];
      if (_pending.contains(sourceId)) {
        // 搜索中渠道：标题 + 进度指示
        children.add(_groupHeader(source.displayName, null, scheme));
        children.add(
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
        continue;
      }
      if (value is List<Track>) {
        if (value.isEmpty) continue;
        children.add(_groupHeader(source.displayName, value.length, scheme));
        for (final track in value) {
          final checked = _selected.contains(track.key);
          children.add(
            Row(
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
            ),
          );
        }
        // 渠道分页页脚
        if (!_exhausted.contains(sourceId)) {
          children.add(_loadMoreTile(sourceId, scheme));
        }
      } else if (value is String) {
        // 渠道失败提示 + 独立重试（迭代计划 §10.6）
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 16,
                  color: scheme.error.withValues(alpha: 0.7),
                ),
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
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '重试 ${source.displayName}',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _retrySource(sourceId),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                ),
              ],
            ),
          ),
        );
      }
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(0, 8, 0, _selecting ? 120 : 160),
      children: children,
    );
  }

  Widget _groupHeader(String name, int? count, ColorScheme scheme) => Padding(
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
          name,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        if (count != null) ...[
          const SizedBox(width: 6),
          Text(
            '$count 首',
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _batchAction(IconData icon, String label, VoidCallback onTap) =>
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
