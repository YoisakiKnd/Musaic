import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/features/lyrics/domain/lyric_bundle.dart';
import 'package:musaic/features/lyrics/domain/yrc_parser.dart';

const _yrcSample = '''
{"t":0,"c":[{"tx":"作词: "},{"tx":"某人"}]}
{"t":100,"c":[{"tx":"作曲: 另一人"}]}
[12590,2960](12590,240,\\u6211)(12830,300,\\u4eec)
[15550,2500](15550,400,w\\u00e9 \\u4eec)(15950,600,唱)
''';

void main() {
  test('头部 JSON 行进入 metadata，不参与计时', () {
    final bundle = YrcParser.parse(_yrcSample);
    expect(bundle.metadata.values.join(), contains('作词'));
    expect(bundle.lines.every((l) => l.start > Duration.zero), isTrue);
  });

  test('字级元组解析与转义还原', () {
    final bundle = YrcParser.parse(_yrcSample);
    expect(bundle.granularity, LyricGranularity.word);

    final first = bundle.lines.first;
    expect(first.text, '我们');
    expect(first.start, const Duration(milliseconds: 12590));
    expect(first.end, const Duration(milliseconds: 12590 + 2960));
    expect(first.words.length, 2);
    expect(first.words.first.start, const Duration(milliseconds: 12590));
    expect(first.words.first.end, const Duration(milliseconds: 12830));
  });

  test('无字级元组时退化为逐行粒度', () {
    final bundle = YrcParser.parse('[1000,2000]');
    expect(bundle.isEmpty, isTrue); // 纯计时无文本 → 无有效行
  });

  test('activeWordAt 返回当前词索引与进度', () {
    final bundle = YrcParser.parse(_yrcSample);
    final line = bundle.lines.first;

    // 第一个字进行中（12590→12830）
    final (:index, :fraction) = line.activeWordAt(
      const Duration(milliseconds: 12710),
    );
    expect(index, 0);
    expect(fraction, greaterThan(0.4));
    expect(fraction, lessThan(0.6));

    // 行尾：最后一个字、进度 1
    final tail = line.activeWordAt(const Duration(milliseconds: 15000));
    expect(tail.index, line.words.length - 1);
    expect(tail.fraction, 1.0);
  });

  test('lineIndexAt 二分定位当前行', () {
    final bundle = YrcParser.parse(_yrcSample);
    expect(bundle.lineIndexAt(Duration.zero), -1);
    expect(
      bundle.lineIndexAt(const Duration(milliseconds: 12600)),
      0,
    );
    expect(
      bundle.lineIndexAt(const Duration(milliseconds: 16000)),
      1,
    );
  });

  test('YTLRC 翻译可按时间合并进主歌词', () {
    final main = YrcParser.parse('[1000,2000](1000,900,a)(1900,1100,b)');
    final trans = YrcParser.parse('[1000,2000](1000,900,甲)(1900,1100,乙)');
    LyricBundle.mergeTranslations(
      base: main.lines,
      translations: trans.lines,
      tolerance: const Duration(milliseconds: 300),
    );
    expect(main.lines.single.translation, '甲乙'); // 整行为单位合并
  });
}
