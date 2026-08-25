import 'package:xml/xml.dart';

import 'lyric_bundle.dart';

/// TTML 逐字歌词解析器（第三方来源，前端文档 §8）。
///
/// 支持 `hh:mm:ss.mmm` / `mm:ss.mmm` / `12.5s` / `900ms` 时钟值；
/// `<p>` 内带时间戳的 `<span>` 视为字级元组；无 span 时退化为逐行。
abstract final class TtmlParser {
  static LyricBundle parse(String source) {
    final lines = <LyricLine>[];
    final metadata = <String, String>{};
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(source);
    } catch (_) {
      return LyricBundle(lines: const <LyricLine>[]);
    }

    for (final node in doc.descendantElements.where((e) => e.name.local == 'p')) {
      final begin = _attr(node, 'begin');
      if (begin == null) continue;
      final start = parseClock(begin);
      if (start == null) continue;
      final end = _attr(node, 'end') != null
          ? parseClock(_attr(node, 'end')!)
          : null;

      final words = <LyricWord>[];
      final buffer = StringBuffer();
      for (final child in node.childElements) {
        if (child.name.local != 'span') continue;
        final spanBegin = _attr(child, 'begin');
        final text = child.innerText.trim();
        if (text.isEmpty) continue;
        buffer.write(text);
        if (spanBegin != null) {
          final wStart = parseClock(spanBegin);
          if (wStart != null) {
            final wEnd = _attr(child, 'end') != null
                ? parseClock(_attr(child, 'end')!)
                : null;
            words.add(
              LyricWord(text: text, start: wStart, end: wEnd),
            );
          }
        }
      }
      if (buffer.isEmpty) {
        buffer.write(node.innerText.trim());
      }
      final text = buffer.toString().trim();
      if (text.isEmpty) continue;

      lines.add(
        LyricLine(
          text: text,
          start: start,
          end: end,
          words: words,
        ),
      );
    }

    // 元信息：ttm:agent / itunes:songwriter 等常见字段尽力收集
    for (final meta in doc.descendantElements
        .where((e) => e.name.local == 'metadata')) {
      for (final child in meta.childElements) {
        final key = child.name.local;
        final value = child.innerText.trim();
        if (value.isNotEmpty) metadata[key] = value;
      }
    }

    final hasWords = lines.isNotEmpty && lines.any((l) => l.hasWords);
    return LyricBundle(
      lines: lines,
      granularity:
          hasWords ? LyricGranularity.word : LyricGranularity.line,
      metadata: metadata,
    );
  }

  /// 解析 TTML 时钟值；无法识别返回 null。
  static Duration? parseClock(String value) {
    final v = value.trim();
    if (v.isEmpty) return null;

    // 毫秒形式：900ms
    final ms = RegExp(r'^(\d+(?:\.\d+)?)ms$').firstMatch(v);
    if (ms != null) {
      return Duration(
        microseconds:
            ((double.parse(ms.group(1)!)) * 1000).round(),
      );
    }
    // 秒形式：12.5s
    final s = RegExp(r'^(\d+(?:\.\d+)?)s$').firstMatch(v);
    if (s != null) {
      return Duration(
        microseconds: (double.parse(s.group(1)!) * 1e6).round(),
      );
    }
    // 冒号时钟：s | m:s | h:m:s（最后一段允许小数）
    final parts = v.split(':');
    final clockPattern =
        RegExp(r'^\d{1,3}(?:\.\d{1,3})?$');
    if (parts.length <= 3 && parts.every(clockPattern.hasMatch)) {
      double parsePart(String p) => double.parse(p);
      var secondsTotal = 0.0;
      for (final part in parts) {
        secondsTotal = secondsTotal * 60 + parsePart(part);
      }
      return Duration(
        microseconds: (secondsTotal * 1e6).round(),
      );
    }
    // 纯数字按秒处理（ticks 场景少见，宽容处理）
    final plain = int.tryParse(v);
    if (plain != null) return Duration(seconds: plain);
    return null;
  }

  static String? _attr(XmlElement element, String localName) {
    for (final attr in element.attributes) {
      if (attr.name.local == localName) return attr.value;
    }
    return null;
  }
}
