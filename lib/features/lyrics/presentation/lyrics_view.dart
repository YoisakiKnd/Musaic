import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/model/track.dart';
import '../../../core/theme/app_tokens.dart';
import '../../player/player_notifier.dart';
import '../application/lyrics_provider.dart';
import '../domain/lyric_bundle.dart';

/// 逐字歌词视图（前端文档 §8）。
///
/// - 进度流驱动高亮；逐字粒度按词填充颜色，逐行粒度整行高亮。
/// - 自动滚动居中；用户手动滚动时暂停跟随 3 秒。
/// - 点击行跳转播放进度。
class LyricsView extends ConsumerStatefulWidget {
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
  ConsumerState<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<LyricsView> {
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
    final lyricsAsync = ref.watch(lyricsProvider(widget.track));
    final position =
        ref.watch(playerNotifierProvider.select((s) => s.position));

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
      child: switch (lyricsAsync) {
        AsyncLoading() => const Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        AsyncValue<LyricBundle?>(:final value?) when value.isEmpty =>
          _hint('暂无歌词'),
        AsyncValue<LyricBundle?>(:final value?) => _buildLines(
            value,
            value.lineIndexAt(position),
          ),
        _ => _hint('暂无歌词'),
      },
    );
  }

  Widget _buildLines(LyricBundle bundle, int activeIndex) {
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
    final activeColor =
        widget.activeColor ?? AppTokens.accent;
    final inactiveColor =
        widget.inactiveColor ?? scheme.onSurface.withValues(alpha: 0.45);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(8, 120, 8, 300),
      itemCount: bundle.lines.length,
      itemBuilder: (context, index) {
        final line = bundle.lines[index];
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
            await ref
                .read(playerNotifierProvider.notifier)
                .seekTo(line.start);
          },
          child: AnimatedPadding(
            duration: AppTokens.durationNormal,
            curve: AppTokens.curveEmphasized,
            padding:
                const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (bundle.supportsWordHighlight && line.hasWords)
                  _WordHighlightLine(
                    line: line,
                    isActive: isActive,
                    baseStyle: baseStyle,
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
                        color: isActive
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
    );
  }

  void _scrollTo(int index) {
    if (!_scrollController.hasClients || index < 0) return;
    // 每行高度不均，用估算步进 + 最大滚动距离约束
    const estimatedLineExtent = 56.0;
    final target =
        (index * estimatedLineExtent -
                (_scrollController.position.viewportDimension / 2) +
                28)
            .clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        );
    _scrollController.animateTo(
      target,
      duration: AppTokens.durationSlow,
      curve: AppTokens.curveEmphasized,
    );
  }

  Widget _hint(String text) => Center(
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: AppTokens.darkTextSecondary),
        ),
      );
}

/// 逐字填充行：已唱词语高亮、当前词按进度渐变、未唱词弱色。
class _WordHighlightLine extends ConsumerWidget {
  const _WordHighlightLine({
    required this.line,
    required this.isActive,
    required this.baseStyle,
  });

  final LyricLine line;
  final bool isActive;
  final TextStyle baseStyle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position =
        ref.watch(playerNotifierProvider.select((s) => s.position));
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
        color = Color.lerp(baseStyle.color ?? Colors.white, accent,
                fraction.clamp(0.0, 1.0)) ??
            accent;
      } else {
        color = baseStyle.color ?? Colors.white;
      }
      spans.add(TextSpan(text: word.text, style: baseStyle.copyWith(color: color)));
    }
    return RichText(
      text: TextSpan(children: spans),
    );
  }
}
