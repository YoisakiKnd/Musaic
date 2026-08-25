import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/features/lyrics/domain/lrc_parser.dart';
import 'package:musaic/features/lyrics/domain/lyric_bundle.dart';

void main() {
  test('解析基础 LRC：时间戳与文本', () {
    final bundle = LrcParser.parse('''
[ti:测试]
[00:01.00]第一行
[00:04.50]第二行
''');
    expect(bundle.metadata['ti'], '测试');
    expect(bundle.lines.length, 2);
    expect(bundle.lines[0].start,
        const Duration(minutes: 0, seconds: 1));
    expect(bundle.lines[0].text, '第一行');
    expect(bundle.lines[1].start, const Duration(seconds: 4, milliseconds: 500));
  });

  test('一行多个时间戳展开为多行', () {
    final bundle = LrcParser.parse('[00:10.00][01:20.00]副歌');
    expect(bundle.lines.length, 2);
    expect(bundle.lines[0].text, '副歌');
    expect(bundle.lines[1].start, const Duration(minutes: 1, seconds: 20));
  });

  test('offset 标签整体偏移（正值提前）', () {
    final bundle = LrcParser.parse('[offset:500]\n[00:05.00]歌词');
    expect(bundle.lines.single.start, const Duration(seconds: 4, milliseconds: 500));
  });

  test('两位小数按厘秒解释', () {
    final bundle = LrcParser.parse('[00:02.25]x');
    expect(bundle.lines.single.start.inMilliseconds, 2250);
  });

  test('双语 LRC：同时间戳第二种语言成为翻译', () {
    final bundle = LrcParser.parse('''
[00:03.00]Hello world
[00:03.00]你好世界
''');
    expect(bundle.lines.length, 1);
    expect(bundle.lines.single.text, 'Hello world');
    expect(bundle.lines.single.translation, '你好世界');
  });

  test('无时间戳与纯间奏行被忽略', () {
    final bundle = LrcParser.parse('''
随便写的文字
[00:01.00][00:05.00]
[00:02.00]真实内容
''');
    expect(bundle.lines.length, 1);
    expect(bundle.lines.single.text, '真实内容');
  });

  test('归一化：行按时间排序并推断结束时间', () {
    final bundle = LrcParser.parse('''
[00:05.00]后
[00:01.00]前
''');
    expect(bundle.lines.map((l) => l.text).toList(), ['前', '后']);
    expect(bundle.lines[0].end, bundle.lines[1].start);
  });

  test('mergeTranslations 按就近合并且尊重阈值', () {
    final base = LyricBundle(lines: [
      LyricLine(text: 'a', start: const Duration(seconds: 1)),
      LyricLine(text: 'b', start: const Duration(seconds: 10)),
    ]).lines;
    final trans = LyricBundle(lines: [
      LyricLine(text: '甲', start: const Duration(milliseconds: 1200)),
      LyricLine(text: '乙', start: const Duration(seconds: 12)),
    ]).lines;

    LyricBundle.mergeTranslations(base: base, translations: trans);
    expect(base[0].translation, '甲');

    // 超过阈值不合并不影响下一行匹配
    final far = LyricBundle(lines: [
      LyricLine(text: '远', start: const Duration(seconds: 9)),
    ]).lines;
    LyricBundle.mergeTranslations(
      base: [base[1]],
      translations: far,
      tolerance: const Duration(milliseconds: 800),
    );
    expect(base[1].translation, isNull);
  });
}
