import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/model/track.dart';
import '../../core/source/music_source.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/nav_intent.dart';
import '../../core/utils/track_link_parser.dart';
import '../player/player_notifier.dart';
import '../shared/error_text.dart';
import '../shared/widgets/confirm_dialog.dart';
import 'search_results_page.dart';

enum _AggregateMode { grouped, merged }

enum _ScopeMode { single, aggregate }

enum _SortMode { relevance, durationAsc, durationDesc }

/// 搜索表单页：默认单一渠道搜索；切到「聚合搜索」才展开多选（默认全选）
/// 与展示/排序选项，避免用户挨个取消勾选。
///
/// [queryIntent] 是外部发起的一次搜索请求
/// （日常可用性计划 D5）。为 null 即用户手动进入，行为与从前完全一致：
/// 只显示历史记录，不自动搜索。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.queryIntent});

  final NavIntent<String>? queryIntent;

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

  /// 重复提交防抖窗口（计划 3.2）。
  ///
  /// 取 600ms：足够覆盖「连按回车 / 连点按钮」的手指节奏，
  /// 又短到用户改完关键词重新搜索时感知不到延迟。
  static const Duration _duplicateSubmitWindow = Duration(milliseconds: 600);
  DateTime? _lastSubmitAt;
  String? _lastSubmitQuery;

  /// 尚未消费的外部请求；[NavIntent.serial] 保证同一次请求只消费一次。
  NavIntent<String>? _pendingIntent;
  int? _consumedSerial;

  @override
  void initState() {
    super.initState();
    _pendingIntent = widget.queryIntent;
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
      // 渠道与历史就绪后再消费外部请求，否则「聚合搜索」会因 _targets 为空
      // 而弹出「请至少选择一个目标渠道」
      _consumePendingIntent();
    });
  }

  @override
  void didUpdateWidget(SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final intent = widget.queryIntent;
    if (intent == null || intent.serial == _consumedSerial) return;
    _pendingIntent = intent;
    if (!_uiReady) return; // 首帧回调会兜底消费
    // 不在 build 期间直接 setState，排到帧末，与首次消费走同一条路径
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _consumePendingIntent();
    });
  }

  /// 消费一次外部搜索请求：切到「聚合搜索」并立即发起。
  ///
  /// 艺人搜索的意义就在于「看到该艺人在**各渠道**的曲目」，
  /// 因此这里强制走聚合、目标全选，而不是沿用页面当前的单渠道选择。
  void _consumePendingIntent() {
    final intent = _pendingIntent;
    if (intent == null) return;
    _pendingIntent = null;
    _consumedSerial = intent.serial;

    final keyword = intent.value.trim();
    if (keyword.isEmpty) return;

    setState(() {
      _scope = _ScopeMode.aggregate;
      _targets =
          ref.read(sourceRegistryProvider).all.map((s) => s.sourceId).toSet();
      _controller.text = keyword;
    });
    unawaited(_submit(keyword));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 打开解析出的链接：按渠道补全曲目详情后直接播放。
  ///
  /// 用「补全详情 → 播放」而非「搜索 id」：分享链接给的是精确的曲目标识，
  /// 搜索会引入歧义（可能匹配到翻唱/同名曲）。
  Future<void> _openTrackLink(TrackLink link) async {
    final source = ref.read(sourceRegistryProvider).resolve(link.sourceId);
    if (source == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('渠道「${link.sourceId}」不可用')));
      return;
    }

    // 先构造最小 Track，再让渠道补全（封面/时长/专辑）
    final placeholder = Track(
      id: link.id,
      sourceId: link.sourceId,
      title: '正在载入…',
      artist: '',
      sourceData: _sourceDataFor(link),
    );

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('正在载入 ${source.displayName} 曲目…')));

    try {
      final detail = await source.getTrackDetail(placeholder);
      if (!mounted) return;
      await ref.read(playerNotifierProvider.notifier).playQueue([detail]);
      if (!mounted) return;
      // push 的 Future 在页面 pop 时才完成，此处无需等待
      unawaited(context.push('/player'));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            loadFailureText(e, tag: 'MusaicSearch', prefix: '无法载入该链接'),
          ),
        ),
      );
    }
  }

  /// 各渠道的 `sourceData` 键名不同，需按渠道填对，
  /// 否则渠道解析播放地址时会取不到标识。
  Map<String, dynamic> _sourceDataFor(TrackLink link) => switch (link
      .sourceId) {
    'netease' => <String, dynamic>{
      'neteaseId': int.tryParse(link.id) ?? link.id,
    },
    'qqmusic' => <String, dynamic>{'songmid': link.id},
    'kugou' => <String, dynamic>{'hash': link.id},
    // 必须与 YouTubeMusicSource.id（ytmusic）一致
    youtubeMusicSourceId => <String, dynamic>{'videoId': link.id},
    'local' => <String, dynamic>{'path': link.id},
    _ => <String, dynamic>{},
  };

  Future<void> _submit(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) {
      // 计划 3.1：空/纯空白提交必须给出反馈。
      // 此前是静默 return——用户按了回车或点了搜索按钮却「什么都没发生」，
      // 会反复重试并怀疑输入法或按钮坏了。
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('请输入搜索关键词')));
      return;
    }

    // 计划 3.2：同一关键词的重复提交防抖。
    //
    // 结果页是独立的 `Navigator.push` 页面，而搜索结果由结果页自己流式接收。
    // 用户连点搜索按钮或连按回车会叠加出多个结果页，返回时要退好几层，
    // 且每次都重复请求所有渠道。窗口内的同一关键词直接忽略；
    // 换关键词、或稍后重新搜同一关键词都不受影响。
    final now = DateTime.now();
    final lastAt = _lastSubmitAt;
    if (_lastSubmitQuery == query &&
        lastAt != null &&
        now.difference(lastAt) < _duplicateSubmitWindow) {
      return;
    }
    _lastSubmitQuery = query;
    _lastSubmitAt = now;

    // 分享链接 / 裸 ID 直达（日常可用性计划 D1）。
    //
    // 搜索框一直提示「搜索 / 链接 / ID」，但此前没有解析实现——
    // 粘链接会被当关键字搜出空结果。现在真正支持：
    // 识别到渠道与曲目 id 时直接拉详情并播放，跳过搜索。
    final link = parseTrackLink(query);
    if (link != null) {
      await _openTrackLink(link);
      return;
    }

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
                // 计划 4.1：把「结果展示」的选择真正传给结果页。
                // 此前该选项只改了本页 _mode，从未向下传递，结果页
                // 恒以合并视图开场 —— 选项等于装饰。
                //
                // 仅在聚合搜索下生效：这组选项只在聚合模式显示，
                // 单渠道搜索时 _mode 仍是未被用户触碰的默认值，
                // 传下去会把单渠道搜索也从合并改成分组（行为回退）。
                initialGrouped:
                    _scope == _ScopeMode.aggregate &&
                    _mode == _AggregateMode.grouped,
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
                    // 历史是用户积累的数据：先确认再清空（用户层交互计划 2.1）
                    final confirmed = await confirmDestructiveAction(
                      context,
                      title: '清空历史搜索？',
                      message: '将删除全部历史搜索记录，该操作不可恢复。',
                    );
                    if (!confirmed || !mounted) return;
                    final repo = ref.read(searchHistoryRepositoryProvider);
                    final cleared = await repo.clear();
                    if (!mounted) return;
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
