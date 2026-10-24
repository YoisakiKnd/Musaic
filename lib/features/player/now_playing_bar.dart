import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart'
    show audioHandlerProvider, libraryRepositoryProvider;
import '../../core/logging/app_logger.dart';
import '../../core/model/track.dart';
import '../../core/theme/app_tokens.dart';
import '../library/data/library_providers.dart';
import '../shared/widgets/track_cover.dart';
import 'player_notifier.dart';
import 'widgets/player_controls.dart';
import 'widgets/queue_panel.dart';

/// 平板 / 桌面的底部播放控制条（桌面音乐软件布局）。
///
/// 左：封面 + 曲名 + 喜欢；中：完整控制 + 可拖动进度；右：歌词 / 队列 / 音量。
/// 手机上空间不够，仍用 `MiniPlayer` + 全屏播放页。
class NowPlayingBar extends ConsumerWidget {
  const NowPlayingBar({super.key});

  static const double height = 84;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerNotifierProvider.select((s) => s.current));
    if (track == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: scheme.outlineVariant, width: 0.5),
          ),
        ),
        child: SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 窄于 820 时收起音量滑条，只留按钮
              final roomy = constraints.maxWidth >= 820;
              return Row(
                children: [
                  Expanded(flex: 3, child: _TrackInfo(track: track)),
                  const Expanded(
                    flex: 4,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [PlayerControls(compact: true), _SeekBar()],
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          tooltip: '歌词与全屏播放',
                          onPressed: () => context.push('/player'),
                          icon: const Icon(Icons.lyrics_outlined, size: 20),
                        ),
                        IconButton(
                          tooltip: '播放队列',
                          onPressed: () => showQueueSheet(context),
                          icon: const Icon(Icons.queue_music_rounded, size: 20),
                        ),
                        if (roomy) const _VolumeControl(),
                        const SizedBox(width: 16),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TrackInfo extends ConsumerWidget {
  const _TrackInfo({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isFavorite = ref.watch(isFavoriteProvider(track));
    final hasError = ref.watch(
      playerNotifierProvider.select((s) => s.error != null),
    );
    return Row(
      children: [
        const SizedBox(width: 12),
        Flexible(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => context.push('/player'),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TrackCover(coverUrl: track.coverUrl, size: 56, radius: 6),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          hasError ? '播放失败，点击查看' : track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                hasError
                                    ? scheme.error
                                    : scheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: isFavorite ? '取消喜欢' : '喜欢',
          onPressed: () => _toggleFavorite(context, ref),
          icon: Icon(
            isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            size: 20,
            color:
                isFavorite
                    ? AppTokens.accent
                    : scheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  Future<void> _toggleFavorite(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final added = await ref
          .read(libraryRepositoryProvider)
          .toggleFavorite(track);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(added ? '已加入喜欢' : '已取消喜欢')));
    } catch (e) {
      AppLog.error('收藏写入失败：${track.key} | $e', tag: 'MusaicLibrary');
      messenger.showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
    }
  }
}

/// 进度条：时间 + 可拖动滑条。拖动期间只改本地值，松手才 seek。
class _SeekBar extends ConsumerStatefulWidget {
  const _SeekBar();

  @override
  ConsumerState<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<_SeekBar> {
  double? _dragMs;

  static String _format(Duration d) {
    final m = d.inMinutes.toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final position = ref.watch(
      playerNotifierProvider.select((s) => s.position),
    );
    final duration = ref.watch(
      playerNotifierProvider.select((s) => s.duration ?? s.current?.duration),
    );
    final totalMs = (duration?.inMilliseconds ?? 0).toDouble();
    final valueMs =
        (_dragMs ?? position.inMilliseconds.toDouble())
            .clamp(0.0, totalMs <= 0 ? 0.0 : totalMs)
            .toDouble();
    final timeStyle = TextStyle(
      fontSize: 11,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
    );

    return RepaintBoundary(
      child: SizedBox(
        height: 22,
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(
                _format(Duration(milliseconds: valueMs.round())),
                textAlign: TextAlign.right,
                style: timeStyle,
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 5,
                  ),
                ),
                child: Slider(
                  value: valueMs,
                  max: totalMs <= 0 ? 1 : totalMs,
                  onChanged:
                      totalMs <= 0 ? null : (v) => setState(() => _dragMs = v),
                  onChangeEnd:
                      totalMs <= 0
                          ? null
                          : (v) {
                            setState(() => _dragMs = null);
                            ref
                                .read(playerNotifierProvider.notifier)
                                .seekTo(Duration(milliseconds: v.round()));
                          },
                ),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                duration == null ? '--:--' : _format(duration),
                style: timeStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 音量：图标（点按静音 / 恢复）+ 滑条。
class _VolumeControl extends ConsumerStatefulWidget {
  const _VolumeControl();

  @override
  ConsumerState<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends ConsumerState<_VolumeControl> {
  late double _volume;
  double _beforeMute = 1;

  @override
  void initState() {
    super.initState();
    _volume = ref.read(audioHandlerProvider).player.volume.clamp(0.0, 1.0);
  }

  void _set(double value) {
    setState(() => _volume = value);
    // 经 Notifier 设置以便持久化，而不是直接改播放器
    ref.read(playerNotifierProvider.notifier).setVolume(value);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: _volume == 0 ? '取消静音' : '静音',
          onPressed: () {
            if (_volume == 0) {
              _set(_beforeMute == 0 ? 1 : _beforeMute);
            } else {
              _beforeMute = _volume;
              _set(0);
            }
          },
          icon: Icon(
            _volume == 0
                ? Icons.volume_off_rounded
                : _volume < 0.5
                ? Icons.volume_down_rounded
                : Icons.volume_up_rounded,
            size: 20,
          ),
        ),
        SizedBox(
          width: 110,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            ),
            child: Slider(value: _volume, onChanged: _set),
          ),
        ),
      ],
    );
  }
}
