import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';

/// 可拖拽进度条：拖动时轨道加粗、显示拇指与缓冲进度（前端文档 §7.3）。
class PlayerProgressBar extends StatefulWidget {
  const PlayerProgressBar({
    super.key,
    required this.position,
    required this.duration,
    this.buffered,
    required this.onSeek,
    this.color,
  });

  final Duration position;
  final Duration duration;
  final Duration? buffered;
  final ValueChanged<Duration> onSeek;
  final Color? color;

  @override
  State<PlayerProgressBar> createState() => _PlayerProgressBarState();
}

class _PlayerProgressBarState extends State<PlayerProgressBar> {
  bool _dragging = false;
  double _dragValue = 0;

  double get _maxMs =>
      widget.duration.inMilliseconds > 0
          ? widget.duration.inMilliseconds.toDouble()
          : 1.0;

  String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = widget.color;
    final value = _dragging
        ? _dragValue
        : (widget.position.inMilliseconds / _maxMs).clamp(0.0, 1.0);
    final buffered =
        ((widget.buffered?.inMilliseconds ?? 0) / _maxMs)
            .clamp(0.0, 1.0);

    return Column(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => setState(() {
            _dragging = true;
            _dragValue = value;
          }),
          onHorizontalDragUpdate: (details) {
            final box = context.findRenderObject()! as RenderBox;
            final fraction =
                (details.localPosition.dx / box.size.width)
                    .clamp(0.0, 1.0);
            setState(() => _dragValue = fraction);
          },
          onHorizontalDragEnd: (_) async {
            final target = Duration(
              milliseconds: (_dragValue * _maxMs).round(),
            );
            setState(() => _dragging = false);
            await Future<void>.delayed(Duration.zero);
            if (!mounted) return;
            widget.onSeek(target); // 拖动结束统一 seek，避免频繁打断解码
          },
          child: Padding(
            padding:
                const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const trackHeight = 3.5;
                final activeHeight =
                    _dragging ? trackHeight * 2 : trackHeight;
                return Center(
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      Container(
                        height: activeHeight,
                        width: constraints.maxWidth,
                        decoration: BoxDecoration(
                          color:
                              scheme.outlineVariant.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(activeHeight),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: buffered,
                        child: Container(
                          height: activeHeight,
                          decoration: BoxDecoration(
                            color: scheme.outlineVariant,
                            borderRadius:
                                BorderRadius.circular(activeHeight),
                          ),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: value,
                        child: Container(
                          height: activeHeight,
                          decoration: BoxDecoration(
                            gradient: accent == null
                                ? AppTokens.brandGradient
                                : null,
                            color: accent,
                            borderRadius:
                                BorderRadius.circular(activeHeight),
                          ),
                        ),
                      ),
                      if (_dragging)
                        Positioned(
                          left:
                              (constraints.maxWidth * value - 7).clamp(0.0,
                                  constraints.maxWidth - 14),
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: scheme.onSurface,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.35),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _format(_dragging
                  ? Duration(milliseconds: (_dragValue * _maxMs).round())
                  : widget.position),
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.6),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              '-${_format(widget.duration - widget.position)}',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.6),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
