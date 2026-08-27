/// 统一歌词模型（前端文档 §8.2）。
///
/// 一份 [LyricBundle] 同时承载逐字与逐行两种粒度；
/// 渲染层根据粒度选择逐字填充或整行高亮。
library;

/// 歌词粒度。
enum LyricGranularity {
  /// 逐字时间轴。
  word,

  /// 仅逐行时间轴。
  line,
}

/// 单个字/词的时间戳。
class LyricWord {
  const LyricWord({
    required this.text,
    required this.start,
    this.end,
  });

  final String text;
  final Duration start;
  final Duration? end;

  Duration get resolvedEnd =>
      end ?? start + const Duration(milliseconds: 400);
}

/// 一行歌词。翻译字段可由解析器在构建后合并写入。
class LyricLine {
  LyricLine({
    required this.text,
    required this.start,
    this.end,
    String? translation,
    this.words = const <LyricWord>[],
  }) : _translation = translation;

  final String text;
  final Duration start;
  final Duration? end;

  /// 逐字时间轴；为空表示该行只有整行时间。
  final List<LyricWord> words;

  String? _translation;

  /// 该行翻译（如网易云 tlyric）。
  String? get translation => _translation;

  set translation(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    _translation = trimmed;
  }

  bool get hasWords => words.isNotEmpty;

  Duration get resolvedEnd {
    if (end != null) return end!;
    if (words.isNotEmpty) return words.last.resolvedEnd;
    return start + const Duration(seconds: 5);
  }

  bool contains(Duration position) =>
      !position.isNegative &&
      position >= start &&
      position < resolvedEnd;

  /// 当前行内的活跃字下标与其填充进度（0~1）。
  ///
  /// 无逐字数据时返回 index = -1；超过行尾返回最后一个字、进度 1。
  ({int index, double fraction}) activeWordAt(Duration position) {
    if (words.isEmpty) return (index: -1, fraction: 0.0);
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      final wordEnd = word.resolvedEnd;
      if (position < word.start) {
        // 尚未唱到：高亮前一个字并视为已完成。
        return (index: i > 0 ? i - 1 : 0, fraction: i > 0 ? 1.0 : 0.0);
      }
      if (position < wordEnd) {
        final total = (wordEnd - word.start).inMilliseconds;
        final elapsed = (position - word.start).inMilliseconds;
        final fraction =
            total <= 0 ? 1.0 : (elapsed / total).clamp(0.0, 1.0);
        return (index: i, fraction: fraction);
      }
    }
    return (index: words.length - 1, fraction: 1.0);
  }
}

/// 完整歌词包。
class LyricBundle {
  LyricBundle({
    required List<LyricLine> lines,
    this.granularity = LyricGranularity.line,
    this.metadata = const <String, String>{},
  }) : lines = _normalize(lines);

  /// 已按 start 升序且结束时间补全的行列表。
  final List<LyricLine> lines;
  final LyricGranularity granularity;
  final Map<String, String> metadata;

  bool get isEmpty => lines.isEmpty;

  bool get supportsWordHighlight =>
      granularity == LyricGranularity.word &&
      lines.any((l) => l.hasWords);

  static List<LyricLine> _normalize(List<LyricLine> raw) {
    final sorted = [...raw]..sort((a, b) => a.start.compareTo(b.start));
    final result = <LyricLine>[];
    for (var i = 0; i < sorted.length; i++) {
      final line = sorted[i];
      final inferredEnd = line.end ??
          (i + 1 < sorted.length
              ? sorted[i + 1].start
              : line.start + const Duration(seconds: 5));
      final normalizedWords = _normalizeWords(line.words, inferredEnd);
      result.add(
        LyricLine(
          text: line.text,
          start: line.start,
          end: inferredEnd,
          translation: line.translation,
          words: normalizedWords,
        ),
      );
    }
    return result;
  }

  static List<LyricWord> _normalizeWords(
    List<LyricWord> raw,
    Duration lineEnd,
  ) {
    if (raw.isEmpty) return const <LyricWord>[];
    final words = [...raw]..sort((a, b) => a.start.compareTo(b.start));
    return [
      for (var i = 0; i < words.length; i++)
        LyricWord(
          text: words[i].text,
          start: words[i].start,
          end: words[i].end ??
              (i + 1 < words.length ? words[i + 1].start : lineEnd),
        ),
    ];
  }

  /// 二分查找当前应高亮的行下标；早于第一行返回 -1。
  int lineIndexAt(Duration position) {
    var lo = 0;
    var hi = lines.length - 1;
    var found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].start <= position) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }

  /// 将翻译按时间就近合并进主歌词（阈值 800ms）。
  static void mergeTranslations({
    required List<LyricLine> base,
    required List<LyricLine> translations,
    Duration tolerance = const Duration(milliseconds: 800),
  }) {
    if (base.isEmpty || translations.isEmpty) return;
    for (final line in base) {
      LyricLine? best;
      Duration? bestDelta;
      for (final candidate in translations) {
        final delta = (candidate.start - line.start).abs();
        if (delta <= tolerance &&
            (bestDelta == null || delta < bestDelta)) {
          bestDelta = delta;
          best = candidate;
        }
      }
      if (best != null) {
        line.translation = best.text;
      }
    }
  }
}
