
import 'package:xml/xml.dart';
import 'lyric_bundle.dart';

/// TTML 歌词解析器。
///
/// 将 TTML/XML 格式歌词转换为 [LyricBundle]。
class TtmlParser {
  TtmlParser._();

  static LyricBundle parse(String ttml, {String? source}) {
    final doc = XmlDocument.parse(ttml);
    final body = doc.rootElement;
    final lines = <LyricLine>[];

    for (final node in body.children.whereType<XmlElement>()) {
      final begin = node.getAttribute('begin');
      final end = node.getAttribute('end');
      if (begin == null || end == null) continue;

      final startTime = _parseTime(begin);
      final endTime = _parseTime(end);
      if (startTime == null || endTime == null) continue;

      final words = <LyricWord>[];
      final text = node.innerText;

      if (text.isNotEmpty) {
        words.add(LyricWord(
          text: text,
          startTime: startTime,
          endTime: endTime,
        ));
      }

      lines.add(LyricLine(
        startTime: startTime,
        endTime: endTime,
        words: words,
      ));
    }

    return LyricBundle(
      lines: lines,
      rawTtml: ttml,
      source: source,
    );
  }

  static Duration? _parseTime(String value) {
    try {
      final regex = RegExp(r'(\d+):(\d+):(\d+\.\d+)');
      final match = regex.firstMatch(value);
      if (match != null) {
        final h = int.parse(match.group(1)!);
        final m = int.parse(match.group(2)!);
        final s = double.parse(match.group(3)!);
        return Duration(hours: h, minutes: m, milliseconds: (s * 1000).round());
      }

      final mmss = RegExp(r'(\d+):(\d+\.\d+)');
      final m2 = mmss.firstMatch(value);
      if (m2 != null) {
        final m = int.parse(m2.group(1)!);
        final s = double.parse(m2.group(2)!);
        return Duration(minutes: m, milliseconds: (s * 1000).round());
      }

      return null;
    } catch (_) {
      return null;
    }
  }
}
