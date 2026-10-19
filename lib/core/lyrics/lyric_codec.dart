/// [LyricBundle] 的 JSON 编解码（架构演进设计 §3.1 歌词缓存的序列化层）。
///
/// 采用紧凑字段名：一首逐字歌词常有上千个 [LyricWord]，
/// 键名每多一个字符，缓存体积就多出几 KB。
///
/// 解码对任何结构异常都返回 null 而不是抛异常——缓存损坏只意味着
/// 「未命中，重新拉取」，不应让歌词区显示错误。
library;

import 'lyric_bundle.dart';

abstract final class LyricCodec {
  /// 编码格式版本。结构变化时提升，旧版本缓存直接视为未命中。
  static const int formatVersion = 1;

  static Map<String, dynamic> encode(LyricBundle bundle) => <String, dynamic>{
    'v': formatVersion,
    'g': bundle.granularity.name,
    if (bundle.metadata.isNotEmpty) 'm': bundle.metadata,
    'l': [for (final line in bundle.lines) _encodeLine(line)],
  };

  static LyricBundle? decode(Object? raw) {
    if (raw is! Map) return null;
    try {
      if (raw['v'] != formatVersion) return null;
      final granularity = LyricGranularity.values.firstWhere(
        (g) => g.name == raw['g'],
        orElse: () => LyricGranularity.line,
      );
      final rawMeta = raw['m'];
      final lines = [
        for (final item in raw['l'] as List<dynamic>)
          _decodeLine(item as Map<dynamic, dynamic>),
      ];
      return LyricBundle(
        lines: lines,
        granularity: granularity,
        metadata:
            rawMeta is Map
                ? {for (final e in rawMeta.entries) '${e.key}': '${e.value}'}
                : const <String, String>{},
      );
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _encodeLine(LyricLine line) => <String, dynamic>{
    't': line.text,
    's': line.start.inMilliseconds,
    if (line.end != null) 'e': line.end!.inMilliseconds,
    if (line.translation != null) 'tr': line.translation,
    if (line.words.isNotEmpty)
      'w': [
        for (final w in line.words)
          [
            w.text,
            w.start.inMilliseconds,
            if (w.end != null) w.end!.inMilliseconds,
          ],
      ],
  };

  static LyricLine _decodeLine(Map<dynamic, dynamic> map) {
    final rawEnd = map['e'];
    final rawWords = map['w'] as List<dynamic>?;
    return LyricLine(
      text: map['t'] as String,
      start: Duration(milliseconds: map['s'] as int),
      end: rawEnd is int ? Duration(milliseconds: rawEnd) : null,
      translation: map['tr'] as String?,
      words: [
        if (rawWords != null)
          for (final w in rawWords.cast<List<dynamic>>())
            LyricWord(
              text: w[0] as String,
              start: Duration(milliseconds: w[1] as int),
              end: w.length > 2 ? Duration(milliseconds: w[2] as int) : null,
            ),
      ],
    );
  }
}
