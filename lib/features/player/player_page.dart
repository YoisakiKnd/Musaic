import 'dart:async' show Timer;
import 'dart:io' show File;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart' show libraryRepositoryProvider;
import '../../core/model/track.dart';
import '../../core/theme/app_tokens.dart';
import '../library/data/library_providers.dart';
import '../lyrics/presentation/lyrics_view.dart';
import '../theme/dynamic_color_provider.dart'
    show
        CoverPalette,
        coverPaletteProvider,
        kFallbackGradientEnd,
        kFallbackGradientStart;
import 'domain/queue_logic.dart';
import 'player_notifier.dart';
import 'widgets/player_controls.dart';
import 'widgets/player_progress_bar.dart';

/// 全屏沉浸式播放器（前端文档 §7.2）。
///
/// 封面取色动态渐变背景（450ms 过渡）+ Hero 封面 + 下滑关闭 +
/// 逐字歌词面板切换 + 定时关闭。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  bool _showLyrics = false;
  double _dragOffset = 0;
  Timer? _sleepTicker;

  @override
  void dispose() {
    _sleepTicker?.cancel();
    super.dispose();
  }

  void _ensureSleepTicker(DateTime? endsAt) {
    if (endsAt == null) {
      _sleepTicker?.cancel();
      _sleepTicker = null;
      return;
    }
    _sleepTicker ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
  }

  Future<void> _toggleFavorite(Track track) async {
    final repository = ref.read(libraryRepositoryProvider);
    final added = await repository.toggleFavorite(track);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(added ? '已加入喜欢' : '已取消喜欢')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(playerNotifierProvider.select((s) => s.current));
    final state = ref.watch(playerNotifierProvider);

    _ensureSleepTicker(state.sleepTimerEndsAt);

    if (track == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final palette =
        ref.watch(coverPaletteProvider(track.coverUrl ?? '')).value ??
            const CoverPalette();
    final gradientTop =
        palette.primary?.withValues(alpha: 0.92) ?? kFallbackGradientStart;
    final gradientBottom =
        palette.secondary?.withValues(alpha: 0.85) ?? kFallbackGradientEnd;

    return Scaffold(
      body: AnimatedContainer(
        duration: AppTokens.durationSlow,
        curve: AppTokens.curveEmphasized,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              gradientTop,
              Color.lerp(gradientBottom, Colors.black, 0.55)!,
              AppTokens.darkBackground,
            ],
          ),
        ),
        child: SafeArea(
          child: Transform.translate(
            offset: Offset(0, _dragOffset),
            child: Column(
              children: [
                _buildHeader(track),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: AppTokens.durationSlow,
                    switchInCurve: AppTokens.curveEmphasized,
                    child: _showLyrics
                        ? LyricsView(
                            key: ValueKey('lyrics-${track.key}'),
                            track: track,
                          )
                        : _buildCoverArea(track),
                  ),
                ),
                _buildBottomSection(context, track),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 头部 ----------

  Widget _buildHeader(Track track) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: '收起',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(Icons.keyboard_arrow_down_rounded,
                color: scheme.onSurface),
          ),
          const Spacer(),
          Text('正在播放',
              style: TextStyle(
                fontSize: 13,
                letterSpacing: 2,
                color: scheme.onSurface.withValues(alpha: 0.6),
              )),
          const Spacer(),
          IconButton(
            tooltip: '喜欢',
            onPressed: () => _toggleFavorite(track),
            icon: Consumer(builder: (context, ref, _) {
              final favorites = ref.watch(favoritesProvider).value ??
                  const <Track>[];
              final isFav = favorites.any((t) => t.key == track.key);
              return Icon(
                isFav
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color:
                    isFav ? AppTokens.accent : scheme.onSurface.withValues(alpha: 0.8),
              );
            }),
          ),
        ],
      ),
    );
  }

  // ---------- 封面区（下滑手势关闭） ----------

  Widget _buildCoverArea(Track track) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) {
        if (details.delta.dy > 0) {
          setState(() => _dragOffset += details.delta.dy);
        }
      },
      onVerticalDragEnd: (details) {
        final velocity = details.velocity.pixelsPerSecond.dy;
        if (_dragOffset > 120 || velocity > 800) {
          Navigator.of(context).maybePop();
        }
        setState(() => _dragOffset = 0);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Center(
          child: Hero(
            tag: 'track-cover-${track.key}',
            child: AspectRatio(
              aspectRatio: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppTokens.radiusCard),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 48,
                      offset: const Offset(0, 20),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppTokens.radiusCard),
                  child: _CoverImage(coverUrl: track.coverUrl),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 底部控制区 ----------

  Widget _buildBottomSection(BuildContext context, Track track) {
    final notifier = ref.read(playerNotifierProvider.notifier);
    final state = ref.watch(playerNotifierProvider);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${track.artist}${track.album == null ? '' : ' — ${track.album}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: scheme.onSurface.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: _showLyrics ? '显示封面' : '显示歌词',
                onPressed: () => setState(() => _showLyrics = !_showLyrics),
                icon: Icon(
                  Icons.lyrics_rounded,
                  size: 22,
                  color: _showLyrics
                      ? AppTokens.accent
                      : scheme.onSurface.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          PlayerProgressBar(
            position: state.position,
            duration: state.duration ?? track.duration ?? Duration.zero,
            buffered: state.buffered,
            onSeek: notifier.seekTo,
          ),
          const SizedBox(height: 4),
          const PlayerControls(accentColor: AppTokens.accent),
          const SizedBox(height: 6),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                state.error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12,
                    color: scheme.error.withValues(alpha: 0.9)),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: () => _openQueueSheet(context),
                icon: const Icon(Icons.queue_music_rounded, size: 18),
                label: Text('队列 ${state.queue.length}'),
              ),
              const SizedBox(width: 12),
              _SleepTimerButton(endsAt: state.sleepTimerEndsAt),
            ],
          ),
        ],
      ),
    );
  }

  // ---------- 队列 / 定时 ----------

  Future<void> _openQueueSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Consumer(builder: (context, ref, _) {
        final state = ref.watch(playerNotifierProvider);
        final notifier = ref.read(playerNotifierProvider.notifier);
        return SafeArea(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: state.queue.length,
            itemBuilder: (itemContext, index) {
              final t = state.queue[index];
              final active = index == state.currentIndex;
              return ListTile(
                leading: Text('${index + 1}',
                    style: TextStyle(color: schemeColor(sheetContext))),
                title: Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight:
                        active ? FontWeight.w700 : FontWeight.w400,
                    color: active
                        ? AppTokens.accent
                        : Theme.of(itemContext)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.9),
                  ),
                ),
                subtitle: Text(t.artist,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () {
                  notifier.playAt(index);
                  Navigator.of(sheetContext).pop();
                },
              );
            },
          ),
        );
      }),
    );
  }
}

Color schemeColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);

/// 定时关闭按钮（对齐 Mei 的定时播放）。
class _SleepTimerButton extends StatelessWidget {
  const _SleepTimerButton({required this.endsAt});

  final DateTime? endsAt;

  @override
  Widget build(BuildContext context) {
    final notifier = ProviderScope.containerOf(context)
        .read(playerNotifierProvider.notifier);
    String label;
    if (endsAt == null) {
      label = '定时';
    } else {
      final remaining = endsAt!.difference(DateTime.now());
      label = remaining.isNegative
          ? '定时'
          : '剩余 ${QueueLogic.formatSleepRemaining(remaining)}';
    }
    return PopupMenuButton<Duration?>(
      tooltip: '定时关闭',
      initialValue: null,
      onSelected: notifier.setSleepTimer,
      itemBuilder: (context) => const [
        PopupMenuItem(value: Duration(minutes: 15), child: Text('15 分钟')),
        PopupMenuItem(value: Duration(minutes: 30), child: Text('30 分钟')),
        PopupMenuItem(value: Duration(minutes: 60), child: Text('60 分钟')),
        PopupMenuDivider(),
        PopupMenuItem<Duration?>(value: null, child: Text('关闭定时')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Icon(
              Icons.bedtime_rounded,
              size: 18,
              color: endsAt != null
                  ? AppTokens.accent
                  : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

/// 播放页封面：网络图 / 本地文件图 / 占位渐变。
class _CoverImage extends StatelessWidget {
  const _CoverImage({required this.coverUrl});

  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    final url = coverUrl;
    final Widget placeholder = Container(
      decoration: const BoxDecoration(gradient: AppTokens.brandGradient),
      child: const Center(
        child: Icon(Icons.album_rounded, size: 96, color: Colors.white24),
      ),
    );
    if (url == null || url.isEmpty) return placeholder;
    if (url.startsWith('file://')) {
      return Image.file(
        File(Uri.parse(url).toFilePath()),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: 512,
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => placeholder,
    );
  }
}
