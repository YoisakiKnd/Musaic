import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/model/track.dart';
import '../../../core/theme/app_tokens.dart';
import '../../settings/settings_providers.dart';
import '../../player/player_notifier.dart';
import '../application/lyrics_provider.dart';
import '../../../core/lyrics/lyric_bundle.dart';

/// 逐字歌词视图（前端文档 §8）。
///
/// - 进度流驱动高亮；逐字粒度按词填充颜色，逐行粒度整行高亮。
/// - 自动滚动居中；用户手动滚动时暂停跟随 3 秒。
/// - 点击行跳转播放进度。
///
/// 重建隔离（迭代计划 §10.4 / B12）：本层只监听歌词数据与偏移设置，
/// 播放进度逐帧变化不会触发整页重建；列表层只监听「当前行下标」，
/// 只有当前行内部随进度刷新。
class LyricsView extends ConsumerWidget {
  const LyricsView({
    super.key,
    required this.track,
    this.textStyle,
    this.activeColor,
    this.inactiveColor,
  });

  final Track track;
  final TextStyle? textStyle;
  final Color? activeColor;
  final Color? inactiveColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricsAsync = ref.watch(lyricsProvider(track));
    // 歌词时间偏移（设置可调）：正值=歌词提前显示。
    final offsetMs = ref.watch(lyricOffsetMsProvider);

    return switch (lyricsAsync) {
      AsyncLoading() => const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      AsyncValue<LyricBundle?>(:final value?) when value.isEmpty => const _Hint(
        '暂无歌词',
      ),
      AsyncValue<LyricBundle?>(:final value?) => _LyricsBody(
        bundle: value,
        offsetMs: offsetMs,
        textStyle: textStyle,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
      ),
      _ => const _Hint('暂无歌词'),
    };
  }
}

/// 歌词列表：仅随「当前行下标」变化重建。
class _LyricsBody extends ConsumerStatefulWidget {
  const _LyricsBody({
    required this.bundle,
    required this.offsetMs,
    this.textStyle,
    this.activeColor,
    this.inactiveColor,
  });

  final LyricBundle bundle;
  final int offsetMs;
  final TextStyle? textStyle;
  final Color? activeColor;
  final Color? inactiveColor;

  @override
  ConsumerState<_LyricsBody> createState() => _LyricsBodyState();
}

class _LyricsBodyState extends ConsumerState<_LyricsBody> {
  final ScrollController _scrollController = ScrollController();
  int _activeLineIndex = -1;
  bool _userScrolling = false;
  DateTime _lastUserScrollAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 精确选择器：position 映射为当前行下标，仅在切行时触发列表重建。
    final activeIndex = ref.watch(
      playerNotifierProvider.select((state) {
        final position =
            state.position + Duration(milliseconds: widget.offsetMs);
        return widget.bundle.lineIndexAt(position);
      }),
    );

    if (activeIndex != _activeLineIndex &&
        !_userScrolling &&
        DateTime.now().difference(_lastUserScrollAt) >
            const Duration(seconds: 3)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollTo(activeIndex);
      });
      _activeLineIndex = activeIndex;
    }
    if (_userScrolling &&
        DateTime.now().difference(_lastUserScrollAt) >
            const Duration(seconds: 3)) {
      _userScrolling = false;
    }

    final scheme = Theme.of(context).colorScheme;
    final activeColor = widget.activeColor ?? AppTokens.accent;
    final inactiveColor =
        widget.inactiveColor ?? scheme.onSurface.withValues(alpha: 0.45);

    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        if (notification.direction == ScrollDirection.idle) {
          _userScrolling = false;
        } else {
          _userScrolling = true;
          _lastUserScrollAt = DateTime.now();
        }
        return false;
      },
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(8, 120, 8, 300),
        itemCount: widget.bundle.lines.length,
        itemBuilder: (context, index) {
          final line = widget.bundle.lines[index];
          final isActive = index == activeIndex;
          final baseStyle = (widget.textStyle ??
                  Theme.of(context).textTheme.titleLarge!)
              .copyWith(
                fontSize: isActive ? 22 : 17,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                color: isActive ? activeColor : inactiveColor,
              );

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              var target = line.start - Duration(milliseconds: widget.offsetMs);
              if (target.isNegative) target = Duration.zero;
              await ref.read(playerNotifierProvider.notifier).seekTo(target);
            },
            child: AnimatedPadding(
              duration: AppTokens.durationNormal,
              curve: AppTokens.curveEmphasized,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.bundle.supportsWordHighlight && line.hasWords)
                    _WordHighlightLine(
                      key: ValueKey('word-${line.start.inMilliseconds}'),
                      line: line,
                      isActive: isActive,
                      baseStyle: baseStyle,
                      offsetMs: widget.offsetMs,
                    )
                  else
                    Text(line.text, style: baseStyle),
                  if ((line.translation ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        line.translation!,
                        style: baseStyle.copyWith(
                          fontSize: isActive ? 15 : 13,
                          fontWeight: FontWeight.w400,
                          color:
                              isActive
                                  ? activeColor.withValues(alpha: 0.85)
                                  : inactiveColor.withValues(alpha: 0.7),
                        ),
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

  void _scrollTo(int index) {
    if (!_scrollController.hasClients || index < 0) return;
    // 每行高度不均，用估算步进 + 最大滚动距离约束
    const estimatedLineExtent = 56.0;
    final target = (index * estimatedLineExtent -
            (_scrollController.position.viewportDimension / 2) +
            28)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      target,
      duration: AppTokens.durationSlow,
      curve: AppTokens.curveEmphasized,
    );
  }
}

/// 逐字填充行：已唱词语高亮、当前词按进度渐变、未唱词弱色。
/// 仅当前行随 position 逐帧刷新（迭代计划 §10.4）。
class _WordHighlightLine extends ConsumerWidget {
  const _WordHighlightLine({
    super.key,
    required this.line,
    required this.isActive,
    required this.baseStyle,
    this.offsetMs = 0,
  });

  final LyricLine line;
  final bool isActive;
  final TextStyle baseStyle;
  final int offsetMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position =
        ref.watch(playerNotifierProvider.select((s) => s.position)) +
        Duration(milliseconds: offsetMs);
    const accent = AppTokens.accent;

    if (!isActive) {
      return Text(line.text, style: baseStyle);
    }

    final (:index, :fraction) = line.activeWordAt(position);
    final spans = <TextSpan>[];
    for (var i = 0; i < line.words.length; i++) {
      final word = line.words[i];
      Color color;
      if (i < index) {
        color = accent;
      } else if (i == index) {
        color =
            Color.lerp(
              baseStyle.color ?? Colors.white,
              accent,
              fraction.clamp(0.0, 1.0),
            ) ??
            accent;
      } else {
        color = baseStyle.color ?? Colors.white;
      }
      spans.add(
        TextSpan(text: word.text, style: baseStyle.copyWith(color: color)),
      );
    }
    return RichText(text: TextSpan(children: spans));
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: AppTokens.darkTextSecondary),
      ),
    );
  }
}
