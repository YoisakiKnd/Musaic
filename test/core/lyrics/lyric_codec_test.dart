import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/core/lyrics/lyric_codec.dart';

/// 歌词缓存的序列化层：编码 → JSON 字符串 → 解码必须无损，
/// 损坏数据必须安全降级为「未命中」（null），不能抛到 UI。
void main() {
  LyricBundle roundTrip(LyricBundle bundle) {
    final json = jsonEncode(LyricCodec.encode(bundle));
    return LyricCodec.decode(jsonDecode(json))!;
  }

  test('逐字歌词往返：行、字、翻译、粒度全部保留', () {
    final original = LyricBundle(
      granularity: LyricGranularity.word,
      metadata: const {'ti': '晴天', 'ar': '周杰伦'},
      lines: [
        LyricLine(
          text: '故事的小黄花',
          start: const Duration(milliseconds: 1200),
          translation: 'The little yellow flower',
          words: const [
            LyricWord(text: '故事', start: Duration(milliseconds: 1200)),
            LyricWord(
              text: '的',
              start: Duration(milliseconds: 1600),
              end: Duration(milliseconds: 1800),
            ),
            LyricWord(text: '小黄花', start: Duration(milliseconds: 1800)),
          ],
        ),
        LyricLine(text: '从出生那年就飘着', start: const Duration(seconds: 4)),
      ],
    );

    final decoded = roundTrip(original);

    expect(decoded.granularity, LyricGranularity.word);
    expect(decoded.supportsWordHighlight, isTrue);
    expect(decoded.metadata, {'ti': '晴天', 'ar': '周杰伦'});
    expect(decoded.lines.map((l) => l.text), ['故事的小黄花', '从出生那年就飘着']);
    expect(decoded.lines.first.translation, 'The little yellow flower');
    expect(decoded.lines.first.end, original.lines.first.end);
    expect(
      decoded.lines.first.words.map((w) => (w.text, w.start, w.end)),
      original.lines.first.words.map((w) => (w.text, w.start, w.end)),
    );
    expect(decoded.lines.last.words, isEmpty);
  });

  test('逐行歌词往返：无逐字数据时不写 w 字段', () {
    final original = LyricBundle(
      lines: [LyricLine(text: '海阔天空', start: const Duration(seconds: 3))],
    );
    final encoded = LyricCodec.encode(original);
    final firstLine = (encoded['l'] as List).first as Map;
    expect(firstLine.containsKey('w'), isFalse);

    final decoded = roundTrip(original);
    expect(decoded.granularity, LyricGranularity.line);
    expect(decoded.lines.single.text, '海阔天空');
    expect(decoded.lines.single.start, const Duration(seconds: 3));
  });

  group('损坏数据降级为 null（不抛异常）', () {
    for (final (name, raw) in <(String, Object?)>[
      ('null', null),
      ('非 Map', 'garbage'),
      ('版本不符', {'v': 999, 'g': 'line', 'l': <dynamic>[]}),
      ('缺少 l', {'v': LyricCodec.formatVersion, 'g': 'line'}),
      (
        '行字段类型错误',
        {
          'v': LyricCodec.formatVersion,
          'g': 'line',
          'l': [
            {'t': 1, 's': 'x'},
          ],
        },
      ),
    ]) {
      test(name, () => expect(LyricCodec.decode(raw), isNull));
    }
  });
}
