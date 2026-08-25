import 'package:flutter/foundation.dart';

/// 歌词粒度级别。
enum LyricGranularity { line, word, character }

/// 统一歌词模型。
@immutable
class LyricBundle {
  const LyricBundle({
    required this.lines,
    this.translationLines = const [],
    this.rawLrc,
    this.rawTtml,
    this.source,
  });

  final List<LyricLine> lines;
  final List<String> translationLines;
  final String? rawLrc;
  final String? rawTtml;
  final String? source;

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;
}

/// 单行歌词。
@immutable
class LyricLine {
  const LyricLine({
    required this.startTime,
    required this.endTime,
    required this.words,
    this.translation,
  });

  final Duration startTime;
  final Duration endTime;
  final List<LyricWord> words;
  final String? translation;
}

/// 逐字歌词。
@immutable
class LyricWord {
  const LyricWord({
    required this.text,
    required this.startTime,
    required this.endTime,
  });

  final String text;
  final Duration startTime;
  final Duration endTime;
}
