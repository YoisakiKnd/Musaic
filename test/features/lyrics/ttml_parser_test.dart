import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/core/lyrics/ttml_parser.dart';

const _wordTtml = '''
<tt xmlns="http://www.w3.org/ns/ttml">
  <body>
    <div>
      <p begin="00:00:01.000" end="00:00:04.000">整行没有字级</p>
      <p begin="0:05.500" end="6s">
        <span begin="5.5s" end="5.8s">你</span>
        <span begin="5800ms" end="6.2s">好</span>
      </p>
    </div>
  </body>
</tt>
''';

void main() {
  test('带 span 的行产生逐字粒度', () {
    final bundle = TtmlParser.parse(_wordTtml);
    expect(bundle.granularity, LyricGranularity.word);
    expect(bundle.supportsWordHighlight, isTrue);

    final withWords =
        bundle.lines.where((l) => l.hasWords).toList();
    expect(withWords.length, 1);
    expect(withWords.single.words.map((w) => w.text), ['你', '好']);
    expect(withWords.single.words.first.start,
        const Duration(milliseconds: 5500));
  });

  test('无 span 行保持整行文本并可降级为 line 粒度', () {
    final bundle = TtmlParser.parse('''
<tt><body><div>
<p begin="1s">纯行歌词</p>
</div></body></tt>
''');
    expect(bundle.granularity, LyricGranularity.line);
    expect(bundle.lines.single.text, '纯行歌词');
    expect(bundle.lines.single.start, const Duration(seconds: 1));
    expect(bundle.lines.single.end, const Duration(seconds: 6));
  });

  group('parseClock', () {
    test('hh:mm:ss.mmm', () {
      expect(TtmlParser.parseClock('00:01:02.345'),
          const Duration(hours: 0, minutes: 1, seconds: 2, milliseconds: 345));
    });
    test('mm:ss.f 两位小数补齐毫秒', () {
      expect(TtmlParser.parseClock('01:02.5'),
          const Duration(minutes: 1, seconds: 2, milliseconds: 500));
    });
    test('秒与毫秒单位', () {
      expect(TtmlParser.parseClock('12.5s'), const Duration(seconds: 12, milliseconds: 500));
      expect(TtmlParser.parseClock('900ms'), const Duration(milliseconds: 900));
    });
    test('非法输入返回 null', () {
      expect(TtmlParser.parseClock('abc'), isNull);
      expect(TtmlParser.parseClock(''), isNull);
    });
  });

  test('损坏的 XML 返回空包而不抛异常', () {
    final bundle = TtmlParser.parse('<tt><body><p begin=');
    expect(bundle.isEmpty, isTrue);
  });
}
