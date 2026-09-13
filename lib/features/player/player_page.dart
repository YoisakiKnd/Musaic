import 'dart:io' show File;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChrome, SystemUiMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart'
    show
        audioHandlerProvider,
        libraryRepositoryProvider,
        sourceRegistryProvider;
import '../../core/logging/app_logger.dart';
import '../../core/model/track.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/cover_network.dart';
import '../library/data/library_providers.dart';
import '../library/widgets/add_to_playlist_sheet.dart';
import '../lyrics/presentation/lyrics_view.dart';
import '../settings/settings_providers.dart';
import '../shared/widgets/confirm_dialog.dart';
import '../theme/dynamic_color_provider.dart'
    show
        CoverPalette,
        coverPaletteProvider,
        kFallbackGradientEnd,
        kFallbackGradientStart;
import 'player_notifier.dart';
import 'widgets/player_controls.dart';
import 'widgets/player_progress_bar.dart';
import 'widgets/sleep_timer_button.dart';

/// 全屏沉浸式播放器（Apple Music 复刻）。
///
/// - 竖屏：大封面 + 标题区 + 进度 + 控制 + 音量 + 功能行；
///   横屏：封面居左，控制列居右。
/// - 背景：封面低分辨率上采样模糊（零着色器成本）/ 无封面时取色渐变。
/// - 任意位置下滑关闭（跟手位移，越过阈值即 pop）；
///   沉浸式隐藏系统栏，退出时恢复。
/// - 逐字歌词面板切换 + 定时关闭 + 音量。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with SingleTickerProviderStateMixin {
  bool _showLyrics = false;
  double _volume = 1.0;

  /// 横屏右侧区域点击切换后的临时结果（null = 尚未点击，用持久化设置作初值）。
  ///
  /// 只影响右侧区域显示歌词还是控件，不回写设置：点击是临时查看，
  /// 不是偏好变更。退出沉浸模式时清回 null，恢复为控件态。
  bool? _landscapeSideLyrics;

  /// 沉浸模式：隐藏系统栏 + 头部/功能行，只留封面与核心控制；
  /// 标题行的全屏按钮随时切换（进入播放页默认开启）。
  bool _immersive = true;

  /// 下滑关闭位移（0=贴住屏幕，1=一屏之外）。
  late final AnimationController _dismiss = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  @override
  void initState() {
    super.initState();
    // 沉浸式：隐藏状态栏/导航栏（下滑呼出，自动回隐）。
    // 首帧后再设置，避免与路由转场争抢系统栏切换
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    });
    // 音量取自持久化设置：PlayerNotifier 在 build 时已把存储值应用到播放器，
    // 这里读取实际生效值，保证滑条与真实音量一致。
    _volume = ref.read(audioHandlerProvider).player.volume.clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _dismiss.dispose();
    super.dispose();
  }

  /// 收藏开关（计划 3.3：补上失败反馈）。
  ///
  /// 此前无 try/catch：写入失败时用户看不到任何提示，
  /// 只有成功路径才有「已加入喜欢」的 SnackBar，失败时静默。
  Future<void> _toggleFavorite(Track track) async {
    final repository = ref.read(libraryRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final wasFavorite = repository.isFavorite(track.key);
    try {
      final added = await repository.toggleFavorite(track);
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(added ? '已加入喜欢' : '已取消喜欢')));
    } catch (e) {
      AppLog.error('收藏写入失败：${track.key} | $e', tag: 'MusaicLibrary');
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(wasFavorite ? '取消喜欢失败，请重试' : '收藏失败，请重试')),
        );
    }
  }

  void _toggleImmersive() {
    setState(() {
      _immersive = !_immersive;
      // 退出沉浸模式 → 右侧恢复为控件态（清掉本次点击的临时结果）。
      if (!_immersive) _landscapeSideLyrics = null;
    });
    SystemChrome.setEnabledSystemUIMode(
      _immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (details.delta.dy <= 0) return;
    final height = MediaQuery.sizeOf(context).height;
    _dismiss.value = (_dismiss.value + details.delta.dy / height).clamp(
      0.0,
      1.0,
    );
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    // 二段上滑：播放页继续上滑 → 打开播放队列（MiniPlayer 上滑进播放页的延续）
    if (velocity < -450 && _dismiss.value == 0) {
      _openQueueSheet(context);
      return;
    }
    if (_dismiss.value > 0.25 || velocity > 800) {
      Navigator.of(context).maybePop();
      return;
    }
    _dismiss.animateBack(
      0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(playerNotifierProvider.select((s) => s.current));
    final error = ref.watch(playerNotifierProvider.select((s) => s.error));

    // 换源提示（D7）：以 SnackBar 告知「已切换到其它渠道」，
    // 避免用户困惑于「怎么换了个版本 / 音质变了」。
    // 用 ref.listen 而非 watch：这是一次性事件，不是持续状态。
    ref.listen(playerNotifierProvider.select((s) => s.sourceSwitchNotice), (
      _,
      notice,
    ) {
      if (notice == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(notice)));
      ref.read(playerNotifierProvider.notifier).clearSourceSwitchNotice();
    });

    if (track == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // 「封面取色动态背景」关闭时统一品牌渐变
    final palette =
        ref.watch(dynamicCoverColorProvider)
            ? ref.watch(coverPaletteProvider(track.coverUrl ?? '')).value ??
                const CoverPalette()
            : const CoverPalette();

    // 强制深色前景：沉浸式背景永远是暗的，浅色主题下也保持 Apple Music 观感
    return Theme(
      data: AppTokens.darkTheme,
      child: Scaffold(
        body: AnimatedBuilder(
          animation: _dismiss,
          builder: (context, child) {
            final height = MediaQuery.sizeOf(context).height;
            return Transform.translate(
              offset: Offset(0, _dismiss.value * height),
              child: Opacity(
                opacity: (1 - _dismiss.value * 0.9).clamp(0.0, 1.0),
                child: child,
              ),
            );
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 全页下滑关闭；歌词区的纵向滚动作为子手势优先，不受影响
            onVerticalDragUpdate: _onDragUpdate,
            onVerticalDragEnd: _onDragEnd,
            child: _PlayerBackground(
              track: track,
              palette: palette,
              child: SafeArea(
                bottom: false,
                child: Stack(
                  children: [
                    OrientationBuilder(
                      builder:
                          (context, orientation) =>
                              orientation == Orientation.landscape
                                  ? _buildLandscape(track)
                                  : _buildPortrait(track),
                    ),
                    // 错误横幅置于最上层：与沉浸模式无关，
                    // 保证解析超时 / 渠道不可用等失败始终可见且可重试（P0 回归）。
                    if (error != null)
                      _PlayerErrorBanner(
                        message: error,
                        onRetry:
                            () =>
                                ref
                                    .read(playerNotifierProvider.notifier)
                                    .retry(),
                        onDismiss:
                            () =>
                                ref
                                    .read(playerNotifierProvider.notifier)
                                    .clearError(),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 竖屏布局 ----------

  Widget _buildPortrait(Track track) {
    return Column(
      children: [
        // 头部常驻（收起/喜欢随时可用）；沉浸模式只隐藏底部功能行与系统栏
        _buildHeader(track),
        Expanded(
          child: AnimatedSwitcher(
            duration: AppTokens.durationSlow,
            switchInCurve: AppTokens.curveEmphasized,
            child:
                _showLyrics
                    ? LyricsView(
                      key: ValueKey('lyrics-${track.key}'),
                      track: track,
                    )
                    : _ArtworkArea(track: track),
          ),
        ),
        _buildTitleRow(track),
        _buildProgress(track),
        const PlayerControls(accentColor: AppTokens.accent),
        _buildVolume(),
        _buildActionRowAnimated(),
      ],
    );
  }

  // ---------- 横屏布局（封面居左 / 控制列居右） ----------

  Widget _buildLandscape(Track track) {
    // 初值取持久化设置「横屏右侧显示歌词」；用户点击过右侧区域后，
    // 以本次点击结果为准（[_landscapeSideLyrics]，不回写设置）。
    final bool lyricsSide =
        _landscapeSideLyrics ?? ref.watch(landscapeLyricsProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child:
          lyricsSide
              ? _buildLandscapeLyrics(track)
              : _buildLandscapeControls(track),
    );
  }

  /// 横屏右侧区域在「歌词 / 控件」两态之间切换（点击驱动）。
  ///
  /// 点击是临时查看，不写回设置；退出沉浸模式时由 [_toggleImmersive] 复位。
  void _toggleLandscapeSide() {
    setState(() {
      final bool current =
          _landscapeSideLyrics ?? ref.read(landscapeLyricsProvider);
      _landscapeSideLyrics = !current;
    });
  }

  /// 横屏控制布局：左 = 头部/封面，右 = 标题/进度/控制/音量/功能行。
  Widget _buildLandscapeControls(Track track) {
    return Row(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: AppTokens.durationSlow,
            switchInCurve: AppTokens.curveEmphasized,
            child:
                _showLyrics
                    ? LyricsView(
                      key: ValueKey('lyrics-${track.key}'),
                      track: track,
                    )
                    : Padding(
                      padding: const EdgeInsets.all(16),
                      child: _ArtworkArea(track: track),
                    ),
          ),
        ),
        SizedBox(
          width: 380,
          child: _LandscapeSideTapTarget(
            onTap: _toggleLandscapeSide,
            hint: '点击切换到歌词',
            child: Column(
              children: [
                _buildTitleRow(track),
                _buildProgress(track),
                const PlayerControls(accentColor: AppTokens.accent),
                _buildVolume(),
                _buildActionRowAnimated(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 横屏歌词布局：左 = 头部/封面/标题/进度/控制/音量，右 = 歌词 + 功能行。
  Widget _buildLandscapeLyrics(Track track) {
    return Row(
      children: [
        Expanded(
          child: Column(
            children: [
              _buildHeader(track),
              Expanded(
                child: AnimatedSwitcher(
                  duration: AppTokens.durationSlow,
                  switchInCurve: AppTokens.curveEmphasized,
                  child:
                      _showLyrics
                          ? LyricsView(
                            key: ValueKey('lyrics-${track.key}'),
                            track: track,
                          )
                          : Padding(
                            padding: const EdgeInsets.all(16),
                            child: _ArtworkArea(track: track),
                          ),
                ),
              ),
              _buildTitleRow(track),
              _buildProgress(track),
              const PlayerControls(accentColor: AppTokens.accent),
              _buildVolume(),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _LandscapeSideTapTarget(
            onTap: _toggleLandscapeSide,
            hint: '点击切换到控件',
            child: Column(
              children: [
                Expanded(
                  child: LyricsView(
                    key: ValueKey('lyr-landscape-${track.key}'),
                    track: track,
                  ),
                ),
                _buildActionRowAnimated(),
              ],
            ),
          ),
        ),
      ],
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
            tooltip: '收起（可下滑关闭）',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(
              Icons.keyboard_arrow_down_rounded,
              color: scheme.onSurface.withValues(alpha: 0.85),
            ),
          ),
          const Spacer(),
          Text(
            '正在播放',
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 2,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const Spacer(),
          // 正在听的歌直接加入歌单（日常可用性计划 D2）
          IconButton(
            tooltip: '加入歌单',
            onPressed: () => AddToPlaylistSheet.show(context, [track]),
            icon: Icon(
              Icons.playlist_add_rounded,
              color: scheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
          IconButton(
            tooltip: '喜欢',
            onPressed: () => _toggleFavorite(track),
            icon: Consumer(
              builder: (context, ref, _) {
                final isFav = ref.watch(isFavoriteProvider(track.key));
                return Icon(
                  isFav
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color:
                      isFav
                          ? AppTokens.accent
                          : scheme.onSurface.withValues(alpha: 0.8),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 标题 / 进度 / 音量 / 功能行 ----------

  Widget _buildTitleRow(Track track) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        color: scheme.onSurface.withValues(alpha: 0.62),
                      ),
                    ),
                    // 音源渠道徽标（D8）：用户需要知道当前听的是哪个渠道——
                    // 换源后尤其重要，否则「怎么音质/版本变了」无从解释。
                    const SizedBox(width: 8),
                    _SourceBadge(sourceId: track.sourceId),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: _showLyrics ? '显示封面' : '显示歌词',
            onPressed: () => setState(() => _showLyrics = !_showLyrics),
            icon: Icon(
              Icons.lyrics_rounded,
              size: 24,
              color:
                  _showLyrics
                      ? AppTokens.accent
                      : scheme.onSurface.withValues(alpha: 0.75),
            ),
          ),
          IconButton(
            tooltip: _immersive ? '退出沉浸模式' : '进入沉浸模式',
            onPressed: _toggleImmersive,
            icon: Icon(
              _immersive
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              size: 24,
              color: scheme.onSurface.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgress(Track track) {
    final notifier = ref.read(playerNotifierProvider.notifier);
    return Consumer(
      builder: (context, ref, _) {
        final position = ref.watch(
          playerNotifierProvider.select((s) => s.position),
        );
        final buffered = ref.watch(
          playerNotifierProvider.select((s) => s.buffered),
        );
        final duration = ref.watch(
          playerNotifierProvider.select((s) => s.duration),
        );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: PlayerProgressBar(
            position: position,
            duration: duration ?? track.duration ?? Duration.zero,
            buffered: buffered,
            onSeek: notifier.seekTo,
          ),
        );
      },
    );
  }

  /// 功能行（沉浸模式下隐藏，切回时平滑出现）。
  Widget _buildActionRowAnimated() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child:
          _immersive
              ? const SizedBox.shrink(key: ValueKey('actions-anim'))
              : KeyedSubtree(
                key: const ValueKey('actions-anim-v'),
                child: _buildActionRow(),
              ),
    );
  }

  Widget _buildVolume() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Icon(
            Icons.volume_down_rounded,
            size: 20,
            color: scheme.onSurface.withValues(alpha: 0.6),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(trackHeight: 3),
              child: Slider(
                value: _volume,
                onChanged: (value) {
                  setState(() => _volume = value);
                  // 经 Notifier 设置以便持久化，而不是直接改播放器
                  ref.read(playerNotifierProvider.notifier).setVolume(value);
                },
              ),
            ),
          ),
          Icon(
            Icons.volume_up_rounded,
            size: 20,
            color: scheme.onSurface.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
  }

  Widget _buildActionRow() {
    final scheme = Theme.of(context).colorScheme;
    return Consumer(
      builder: (context, ref, _) {
        final error = ref.watch(playerNotifierProvider.select((s) => s.error));
        final queueLength = ref.watch(
          playerNotifierProvider.select((s) => s.queue.length),
        );
        final speed = ref.watch(playerNotifierProvider.select((s) => s.speed));
        return Padding(
          padding: EdgeInsets.fromLTRB(
            0,
            4,
            0,
            error != null ? 4 : MediaQuery.paddingOf(context).bottom + 10,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    error,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.error.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: () => _openQueueSheet(context),
                    icon: const Icon(Icons.queue_music_rounded, size: 18),
                    label: Text('队列 $queueLength'),
                  ),
                  const SizedBox(width: 12),
                  const SleepTimerButton(),
                  const SizedBox(width: 12),
                  _SpeedButton(speed: speed),
                  const SizedBox(width: 12),
                  IconButton(
                    tooltip: '播放器设置',
                    onPressed: () => _openPlayerSettingsSheet(context),
                    icon: Icon(
                      Icons.tune_rounded,
                      size: 20,
                      color: scheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------- 播放器内设置面板 ----------

  Future<void> _openPlayerSettingsSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder:
          (sheetContext) => SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.75,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Text(
                        '播放器设置',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    // ---------- 音质 ----------
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
                      child: Text(
                        '音质（下次播放生效）',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Consumer(
                        builder: (context, ref, _) {
                          final quality = ref.watch(audioQualityProvider);
                          return SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<AudioQuality>(
                              segments: const [
                                ButtonSegment(
                                  value: AudioQuality.low,
                                  label: Text('流畅 128k'),
                                ),
                                ButtonSegment(
                                  value: AudioQuality.normal,
                                  label: Text('标准 192k'),
                                ),
                                ButtonSegment(
                                  value: AudioQuality.high,
                                  label: Text('高品质 320k'),
                                ),
                              ],
                              selected: {quality},
                              onSelectionChanged:
                                  (selection) => ref
                                      .read(audioQualityProvider.notifier)
                                      .set(selection.first),
                            ),
                          );
                        },
                      ),
                    ),
                    const Divider(height: 24),
                    // ---------- 开关组 ----------
                    Consumer(
                      builder: (context, ref, _) {
                        return Column(
                          children: [
                            SwitchListTile(
                              title: const Text('蜂窝网络自动降质'),
                              subtitle: const Text(
                                '移动流量下自动降低一档音质',
                                style: TextStyle(fontSize: 12),
                              ),
                              value: ref.watch(cellularAutoDowngradeProvider),
                              onChanged:
                                  (value) => ref
                                      .read(
                                        cellularAutoDowngradeProvider.notifier,
                                      )
                                      .set(value),
                            ),
                            SwitchListTile(
                              title: const Text('横屏右侧显示歌词'),
                              subtitle: const Text(
                                '关闭时横屏右侧为控制面板',
                                style: TextStyle(fontSize: 12),
                              ),
                              value: ref.watch(landscapeLyricsProvider),
                              onChanged:
                                  (value) => ref
                                      .read(landscapeLyricsProvider.notifier)
                                      .set(value),
                            ),
                            SwitchListTile(
                              title: const Text('封面模糊背景'),
                              subtitle: const Text(
                                '关闭改用取色渐变',
                                style: TextStyle(fontSize: 12),
                              ),
                              value: ref.watch(enableGlassProvider),
                              onChanged:
                                  (value) => ref
                                      .read(enableGlassProvider.notifier)
                                      .set(value),
                            ),
                            SwitchListTile(
                              title: const Text('封面取色动态背景'),
                              subtitle: const Text(
                                '关闭统一使用品牌渐变',
                                style: TextStyle(fontSize: 12),
                              ),
                              value: ref.watch(dynamicCoverColorProvider),
                              onChanged:
                                  (value) => ref
                                      .read(dynamicCoverColorProvider.notifier)
                                      .set(value),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  // ---------- 队列底部弹层 ----------

  Future<void> _openQueueSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder:
          (sheetContext) => Consumer(
            builder: (context, ref, _) {
              final state = ref.watch(playerNotifierProvider);
              final notifier = ref.read(playerNotifierProvider.notifier);
              return SafeArea(
                child: SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.6,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                        child: Row(
                          children: [
                            Text(
                              '播放队列（${state.queue.length}）',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed:
                                  state.queue.length > 1
                                      ? () async {
                                        // 清空队列会丢弃用户手工排好的顺序
                                        // （尤其「下一首播放」的插入），
                                        // 因此先确认（用户层交互计划 2.1）。
                                        final confirmed =
                                            await confirmDestructiveAction(
                                              context,
                                              title: '清空播放队列？',
                                              message:
                                                  '将移除队列中除当前曲目外的全部曲目，该操作不可恢复。',
                                            );
                                        if (!confirmed) return;
                                        notifier.clearQueue();
                                      }
                                      : null,
                              icon: const Icon(
                                Icons.delete_sweep_rounded,
                                size: 18,
                              ),
                              label: const Text('清空'),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: ReorderableListView.builder(
                          padding: const EdgeInsets.only(bottom: 96),
                          itemCount: state.queue.length,
                          // onReorderItem：newIndex 已按移除后语义给出，直接转发
                          onReorderItem: notifier.moveInQueue,
                          itemBuilder: (context, index) {
                            final t = state.queue[index];
                            final active = index == state.currentIndex;
                            return ListTile(
                              key: ValueKey('${t.key}@$index'),
                              leading:
                                  active
                                      ? const Icon(
                                        Icons.equalizer_rounded,
                                        size: 20,
                                        color: AppTokens.accent,
                                      )
                                      : Icon(
                                        Icons.drag_handle_rounded,
                                        size: 20,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.4),
                                      ),
                              title: Text(
                                t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight:
                                      active
                                          ? FontWeight.w700
                                          : FontWeight.w400,
                                ),
                              ),
                              subtitle: Text(
                                '${t.artist} · ${t.sourceId}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: IconButton(
                                tooltip: '从队列移除',
                                icon: Icon(
                                  Icons.close_rounded,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.5),
                                ),
                                onPressed:
                                    () => notifier.removeFromQueue(index),
                              ),
                              onTap: () {
                                notifier.playAt(index);
                                Navigator.of(sheetContext).pop();
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
    );
  }
}

/// 横屏右侧区域的点击切换外壳（歌词 ↔ 控件）。
///
/// 只在右侧整块区域加一层点击识别：内部按钮 / 滑条自带的手势识别器
/// 在竞技场中优先胜出，因此原有控件功能不受影响；空白处点击才触发切换。
/// 用 [Semantics] 暴露提示，不额外占用视觉空间。
class _LandscapeSideTapTarget extends StatelessWidget {
  const _LandscapeSideTapTarget({
    required this.onTap,
    required this.hint,
    required this.child,
  });

  final VoidCallback onTap;
  final String hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      hint: hint,
      child: GestureDetector(
        // translucent：透明区域也参与命中，保证「整块区域」都可点，
        // 同时不遮挡子控件的事件（opaque 会抢走子控件之外的命中，
        // 但此处子控件已铺满，用 translucent 更保守）。
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        child: child,
      ),
    );
  }
}

/// 沉浸式背景：封面 24px 上采样模糊（零着色器成本）+ 底部压暗渐变；
/// 无封面时回退取色渐变。
class _PlayerBackground extends ConsumerWidget {
  const _PlayerBackground({
    required this.track,
    required this.palette,
    required this.child,
  });

  final Track track;
  final CoverPalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = track.coverUrl;
    final Widget backdrop;
    // 「播放页封面模糊背景」关闭时改用取色渐变
    if (ref.watch(enableGlassProvider) && url != null && url.isNotEmpty) {
      final Widget image;
      if (url.startsWith('file://')) {
        image = Image.file(
          File(Uri.parse(url).toFilePath()),
          fit: BoxFit.cover,
          cacheWidth: 24,
          filterQuality: FilterQuality.low,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        );
      } else {
        image = CachedNetworkImage(
          imageUrl: normalizeCoverUrl(url),
          httpHeaders: coverHttpHeaders(url),
          fit: BoxFit.cover,
          memCacheWidth: 24,
          filterQuality: FilterQuality.low,
          placeholder: (_, _) => const SizedBox.shrink(),
          errorWidget: (_, _, _) => const SizedBox.shrink(),
        );
      }
      backdrop = Stack(
        fit: StackFit.expand,
        children: [
          image,
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.42),
                  Colors.black.withValues(alpha: 0.58),
                  Colors.black.withValues(alpha: 0.82),
                ],
              ),
            ),
          ),
        ],
      );
    } else {
      final gradientTop =
          palette.primary?.withValues(alpha: 0.92) ?? kFallbackGradientStart;
      final gradientBottom =
          palette.secondary?.withValues(alpha: 0.85) ?? kFallbackGradientEnd;
      backdrop = AnimatedContainer(
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
      );
    }
    return Stack(fit: StackFit.expand, children: [backdrop, child]);
  }
}

/// 大封面区（Apple Music：近方角 + 大投影，随曲目切换）。
class _ArtworkArea extends StatelessWidget {
  const _ArtworkArea({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
      child: Center(
        child: AspectRatio(
          aspectRatio: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 44,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _CoverImage(coverUrl: track.coverUrl),
            ),
          ),
        ),
      ),
    );
  }
}

/// 倍速播放按钮。
class _SpeedButton extends ConsumerWidget {
  const _SpeedButton({required this.speed});

  final double speed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(playerNotifierProvider.notifier);
    return PopupMenuButton<double>(
      tooltip: '倍速播放',
      onSelected: notifier.setSpeed,
      itemBuilder:
          (context) => const [
            PopupMenuItem(value: 0.75, child: Text('0.75×')),
            PopupMenuItem(value: 1.0, child: Text('1.0×（标准）')),
            PopupMenuItem(value: 1.25, child: Text('1.25×')),
            PopupMenuItem(value: 1.5, child: Text('1.5×')),
            PopupMenuItem(value: 2.0, child: Text('2.0×')),
          ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Icon(
              Icons.speed_rounded,
              size: 18,
              color:
                  speed != 1.0
                      ? AppTokens.accent
                      : Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 6),
            Text(
              speed == 1.0 ? '倍速' : '$speed×',
              style: const TextStyle(fontSize: 13),
            ),
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
        cacheWidth: 512, // 解码尺寸上限（迭代计划 §9.1）
        errorBuilder: (_, _, _) => placeholder,
      );
    }
    return CachedNetworkImage(
      imageUrl: normalizeCoverUrl(url),
      httpHeaders: coverHttpHeaders(url),
      fit: BoxFit.cover,
      memCacheWidth: 512,
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => placeholder,
    );
  }
}

/// 播放错误横幅：覆盖在播放页最上层，不受沉浸模式影响。
///
/// 播放失败（解析超时 / 渠道不可用 / 解码失败）必须始终可见，
/// 并提供「重试」与「关闭」两个出口（P0 回归守护）。
class _PlayerErrorBanner extends StatelessWidget {
  const _PlayerErrorBanner({
    required this.message,
    required this.onRetry,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: 8,
      left: 12,
      right: 12,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 18,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onErrorContainer,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('重试'),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: onDismiss,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: scheme.onErrorContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 音源渠道徽标（日常可用性计划 D8）。
///
/// 播放页此前完全不显示音源渠道：换源后用户只看到「歌还是那首」，
/// 无法解释音质/版本变化。徽标给出明确归属。
class _SourceBadge extends ConsumerWidget {
  const _SourceBadge({required this.sourceId});

  final String sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(sourceRegistryProvider).resolve(sourceId);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppTokens.accent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppTokens.radiusChip / 2),
      ),
      child: Text(
        source?.displayName ?? sourceId,
        style: const TextStyle(
          fontSize: 10,
          color: AppTokens.accent,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
