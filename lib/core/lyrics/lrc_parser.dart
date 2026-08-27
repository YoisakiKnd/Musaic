import 'lyric_bundle.dart';

/// LRC 逐行歌词解析器（三级降级的保底格式）。
///
/// 支持：多时间戳行、`[offset:±ms]` 全局偏移、`[ti:][ar:][al:]` 元信息、
/// 双语 LRC（同文件内相同时间戳的第二种语言作为翻译）。
abstract final class LrcParser {
  static final RegExp _stamp = RegExp(
    r'^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]',
  );
  static final RegExp _metaTag =
      RegExp(r'^\[([a-zA-Z#]+):([^\]]*)\]');

  static LyricBundle parse(String source) {
    final timed = <(Duration, String)>[];
    final metadata = <String, String>{};
    var offsetMs = 0;

    for (final raw in source.split(RegExp(r'\r\n|\r|\n'))) {
      var line = raw.trim();
      if (line.isEmpty) continue;

      // 元信息标签
      final meta = _metaTag.firstMatch(line);
      if (meta != null && !_stamp.hasMatch(line)) {
        final key = meta.group(1)!.toLowerCase();
        final value = meta.group(2)!.trim();
        if (key == 'offset') {
          offsetMs = int.tryParse(value) ?? 0;
        } else if (value.isNotEmpty) {
          metadata[key] = value;
        }
        continue;
      }

      // 连续时间戳
      final stamps = <Duration>[];
      while (true) {
        final m = _stamp.firstMatch(line);
        if (m == null) break;
        final minutes = int.parse(m.group(1)!);
        final seconds = int.parse(m.group(2)!);
        final fractionStr = m.group(3) ?? '0';
        final fractionMs = int.parse(fractionStr) *
            (fractionStr.length == 2 ? 10 : (fractionStr.length == 1 ? 100 : 1));
        stamps.add(
          Duration(
            minutes: minutes,
            seconds: seconds,
            milliseconds: fractionMs,
          ),
        );
        line = line.substring(m.end);
      }
      if (stamps.isEmpty) continue;

      final content = line.trim();
      if (content.isEmpty) continue; // 纯间奏标记行
      for (final stamp in stamps) {
        final shifted =
            stamp - Duration(milliseconds: offsetMs);
        timed.add((shifted.isNegative ? Duration.zero : shifted, content));
      }
    }

    // 同时间戳多语言 → 首行为原文，其余为翻译
    timed.sort((a, b) => a.$1.compareTo(b.$1));
    final lines = <LyricLine>[];
    final translationsByStart = <Duration, String>{};
    for (final (start, text) in timed) {
      final key = _roundTo(start);
      if (!lines.any((l) => _roundTo(l.start) == key)) {
        lines.add(LyricLine(text: text, start: start));
      } else if (!translationsByStart.containsKey(key)) {
        translationsByStart[key] = text;
      }
    }
    for (final line in lines) {
      final t = translationsByStart[_roundTo(line.start)];
      if (t != null) line.translation = t;
    }

    return LyricBundle(lines: lines, metadata: metadata);
  }

  /// 时间戳对齐容差：10ms。
  static Duration _roundTo(Duration d) =>
      Duration(milliseconds: (d.inMilliseconds / 10).round() * 10);
}
