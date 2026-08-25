import 'lyric_bundle.dart';

/// 网易云 YRC 逐字歌词解析器（官方逐字来源）。
///
/// 格式示例：
/// ```
/// {"t":0,"c":[{"tx":"作词: 某人"}]}          ← 头部元信息（非计时行）
/// [12590,2960](12590,240,我)(12830,180,们)   ← 行起点/时长 + 字级元组
/// ```
abstract final class YrcParser {
  static final RegExp _lineHead =
      RegExp(r'^\[(\d+),(\d+)\]');
  static final RegExp _wordTuple =
      RegExp(r'\((\d+),(\d+),((?:[^()\\]|\\.)*)\)');

  static LyricBundle parse(String source) {
    final lines = <LyricLine>[];
    final metadata = <String, String>{};
    var headerIndex = 0;

    for (final raw in source.split(RegExp(r'\r\n|\r|\n'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('{')) {
        final text = _parseHeaderText(line);
        if (text != null && text.trim().isNotEmpty) {
          metadata['header${headerIndex++}'] = text.trim();
        }
        continue;
      }

      final head = _lineHead.firstMatch(line);
      if (head == null) continue;
      final lineStart = int.parse(head.group(1)!);
      final lineDuration = int.parse(head.group(2)!);

      if (!_wordTuple.hasMatch(line)) continue; // 纯计时无文本：跳过

      final words = <LyricWord>[];
      for (final m in _wordTuple.allMatches(line)) {
        final start = int.parse(m.group(1)!);
        final dur = int.parse(m.group(2)!);
        final text = _unescape(m.group(3) ?? '');
        if (text.isEmpty) continue;
        words.add(
          LyricWord(
            text: text,
            start: Duration(milliseconds: start),
            end: Duration(milliseconds: start + dur),
          ),
        );
      }

      final fullText =
          words.map((w) => w.text).join();
      lines.add(
        LyricLine(
          text: fullText,
          start: Duration(milliseconds: lineStart),
          end: Duration(milliseconds: lineStart + lineDuration),
          words: words,
        ),
      );
    }

    return LyricBundle(
      lines: lines,
      granularity:
          wordsPresent(lines) ? LyricGranularity.word : LyricGranularity.line,
      metadata: metadata,
    );
  }

  static bool wordsPresent(List<LyricLine> lines) =>
      lines.isNotEmpty && lines.any((l) => l.hasWords);

  /// 头部行 `{"t":..,"c":[{"tx":"作词: "},{"tx":"某人"}]}` → `作词: 某人`。
  static String? _parseHeaderText(String jsonLine) {
    final txMatches = RegExp(r'"tx"\s*:\s*"((?:[^"\\]|\\.)*)"')
        .allMatches(jsonLine);
    if (txMatches.isEmpty) return null;
    return txMatches
        .map((m) => _unescape(m.group(1) ?? ''))
        .join();
  }

  /// 还原 YRC 文本中的常见转义。
  static String _unescape(String input) {
    final buffer = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch != '\\' || i + 1 >= input.length) {
        buffer.write(ch);
        continue;
      }
      final next = input[++i];
      switch (next) {
        case 'n':
          buffer.write('\n');
        case 'r':
          buffer.write('\r');
        case 't':
          buffer.write('\t');
        case 'u':
          // 需要当前位置之后再读 4 个十六进制字符
          if (i + 4 < input.length) {
            final hex = input.substring(i + 1, i + 5);
            final code = int.tryParse(hex, radix: 16);
            if (code != null) {
              buffer.write(String.fromCharCode(code));
              i += 4;
            } else {
              buffer.write(next);
            }
          } else {
            buffer.write(next);
          }
        default:
          buffer.write(next);
      }
    }
    return buffer.toString();
  }
}
