import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/model/track.dart';
import '../../core/source/music_source.dart';
import '../../core/theme/app_tokens.dart';
import 'search_results_page.dart';

enum _AggregateMode { grouped, merged }

enum _ScopeMode { single, aggregate }

enum _SortMode { relevance, durationAsc, durationDesc }

/// 搜索表单页：默认单一渠道搜索；切到「聚合搜索」才展开多选（默认全选）
/// 与展示/排序选项，避免用户挨个取消勾选。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  _ScopeMode _scope = _ScopeMode.single;
  String? _singleTarget;
  Set<String> _targets = <String>{};
  _AggregateMode _mode = _AggregateMode.grouped;
  _SortMode _sort = _SortMode.relevance;
  List<String> _history = const <String>[];
  bool _uiReady = false;
  int _searchGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sources = ref.read(sourceRegistryProvider).all;
      setState(() {
        // 单一模式优先选渠道声明的默认渠道（preferredByDefault），无则取第一个
        _singleTarget =
            sources
                .where((s) => s.preferredByDefault)
                .map((s) => s.sourceId)
                .firstOrNull ??
            (sources.isNotEmpty ? sources.first.sourceId : null);
        // 聚合模式默认全选
        _targets = sources.map((s) => s.sourceId).toSet();
        _history = ref.read(searchHistoryRepositoryProvider).load();
        _uiReady = true;
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) return;
    final generation = ++_searchGeneration;
    final registry = ref.read(sourceRegistryProvider);
    final List<MusicSource> sources;
    if (_scope == _ScopeMode.single) {
      final single = registry.resolve(_singleTarget ?? '');
      if (single == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请选择一个搜索渠道')));
        return;
      }
      sources = [single];
    } else {
      sources = registry.all
          .where((s) => _targets.contains(s.sourceId))
          .toList(growable: false);
    }
    if (sources.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请至少选择一个目标渠道')));
      return;
    }

    // 历史记录异步落库，不阻塞进结果页
    final historyRepo = ref.read(searchHistoryRepositoryProvider);
    unawaited(
      historyRepo.add(query).then((nextHistory) {
        if (mounted && generation == _searchGeneration) {
          setState(() => _history = nextHistory);
        }
      }),
    );

    // 立即进入结果页，由结果页按渠道流式接收结果（迭代计划 §10.6 / B19：
    // 搜索首屏不再等待最慢渠道，先到先展示）
    if (!mounted) return;
    unawaited(
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder:
              (_) => SearchResultsPage(
                query: query,
                results: const <String, Object>{},
                merged: const <Track>[],
                pendingSources: sources
                    .map((s) => s.sourceId)
                    .toList(growable: false),
                sortMode: switch (_sort) {
                  _SortMode.relevance => SearchSortMode.relevance,
                  _SortMode.durationAsc => SearchSortMode.durationAsc,
                  _SortMode.durationDesc => SearchSortMode.durationDesc,
                },
              ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(sourceRegistryProvider).all;
    if (!_uiReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: TextField(
          controller: _controller,
          textInputAction: TextInputAction.search,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: '搜索 / 链接 / ID',
            prefixIcon: const Icon(
              Icons.search_rounded,
              color: AppTokens.accent,
            ),
            filled: true,
            fillColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(26),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_upward_rounded),
            tooltip: '搜索',
            onPressed: () => _submit(_controller.text),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 160),
        children: [
          _sectionLabel('搜索范围'),
          Wrap(
            spacing: 8,
            children: [
              _choiceChip(
                '单曲搜索',
                _scope == _ScopeMode.single,
                () => setState(() => _scope = _ScopeMode.single),
              ),
              _choiceChip(
                '聚合搜索',
                _scope == _ScopeMode.aggregate,
                () => setState(() => _scope = _ScopeMode.aggregate),
              ),
            ],
          ),
          if (_scope == _ScopeMode.single) ...[
            _sectionLabel('搜索渠道'),
            _buildSingleTargetChips(sources),
          ] else ...[
            Row(
              children: [
                Expanded(child: _sectionLabel('搜索渠道')),
                TextButton(
                  onPressed:
                      () => setState(() {
                        _targets = sources.map((s) => s.sourceId).toSet();
                      }),
                  child: const Text('全选'),
                ),
                TextButton(
                  onPressed: () => setState(() => _targets = <String>{}),
                  child: const Text('全部取消'),
                ),
              ],
            ),
            _buildAggregateTargetChips(sources),
            _sectionLabel('结果展示'),
            Wrap(
              spacing: 8,
              children: [
                _choiceChip(
                  '分开展示',
                  _mode == _AggregateMode.grouped,
                  () => setState(() => _mode = _AggregateMode.grouped),
                ),
                _choiceChip(
                  '合并展示',
                  _mode == _AggregateMode.merged,
                  () => setState(() => _mode = _AggregateMode.merged),
                ),
              ],
            ),
            _sectionLabel('排序'),
            Wrap(
              spacing: 8,
              children: [
                _choiceChip(
                  '相关度',
                  _sort == _SortMode.relevance,
                  () => setState(() => _sort = _SortMode.relevance),
                ),
                _choiceChip(
                  '时长 ↑',
                  _sort == _SortMode.durationAsc,
                  () => setState(() => _sort = _SortMode.durationAsc),
                ),
                _choiceChip(
                  '时长 ↓',
                  _sort == _SortMode.durationDesc,
                  () => setState(() => _sort = _SortMode.durationDesc),
                ),
              ],
            ),
          ],
          if (_history.isNotEmpty) ...[
            Row(
              children: [
                Expanded(child: _sectionLabel('历史搜索')),
                IconButton(
                  tooltip: '清空历史',
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  onPressed: () async {
                    final repo = ref.read(searchHistoryRepositoryProvider);
                    final cleared = await repo.clear();
                    setState(() => _history = cleared);
                  },
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final keyword in _history)
                  ActionChip(
                    label: Text(keyword, style: const TextStyle(fontSize: 13)),
                    onPressed: () {
                      _controller.text = keyword;
                      _submit(keyword);
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
    ),
  );

  /// 单一模式：渠道单选（点谁搜谁）。
  Widget _buildSingleTargetChips(List<MusicSource> sources) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final source in sources)
          _choiceChip(
            source.displayName,
            _singleTarget == source.sourceId,
            () => setState(() => _singleTarget = source.sourceId),
          ),
      ],
    );
  }

  /// 聚合模式：渠道多选（默认全选）。
  Widget _buildAggregateTargetChips(List<MusicSource> sources) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final source in sources)
          FilterChip(
            label: Text(source.displayName),
            selected: _targets.contains(source.sourceId),
            onSelected:
                (selected) => setState(() {
                  selected
                      ? _targets.add(source.sourceId)
                      : _targets.remove(source.sourceId);
                }),
            selectedColor: AppTokens.accent.withValues(alpha: 0.18),
            checkmarkColor: AppTokens.accent,
            labelStyle: TextStyle(
              fontSize: 13,
              color:
                  _targets.contains(source.sourceId) ? AppTokens.accent : null,
              fontWeight:
                  _targets.contains(source.sourceId)
                      ? FontWeight.w600
                      : FontWeight.w400,
            ),
          ),
      ],
    );
  }

  Widget _choiceChip(String label, bool selected, VoidCallback onTap) =>
      FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        selectedColor: AppTokens.accent.withValues(alpha: 0.18),
        checkmarkColor: AppTokens.accent,
        showCheckmark: false,
        labelStyle: TextStyle(
          fontSize: 13,
          color: selected ? AppTokens.accent : null,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      );
}
