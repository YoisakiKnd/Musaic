import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/model/work_id.dart';

/// 作品身份归一化（架构演进设计 §2.2）。
///
/// 本测试是设计的**核心假设验证**：不同渠道对同一首歌的不同写法，
/// 必须归一到同一个 WorkId；而不同的歌**必须不被合并**。
///
/// 用例取材于四个渠道实际返回的命名习惯（含全角标点、版本后缀、
/// 艺人顺序差异、feat. 标注差异）。
void main() {
  group('标题归一化', () {
    test('去除版本修饰括号', () {
      expect(normalizeWorkTitle('海阔天空'), normalizeWorkTitle('海阔天空 (Live)'));
      expect(normalizeWorkTitle('晴天'), normalizeWorkTitle('晴天 (Remastered)'));
      expect(normalizeWorkTitle('夜曲'), normalizeWorkTitle('夜曲【伴奏】'));
      expect(
        normalizeWorkTitle('Bohemian Rhapsody'),
        normalizeWorkTitle('Bohemian Rhapsody (Remastered 2011)'),
      );
    });

    test('去除 feat. 标注（各渠道写法不一）', () {
      expect(
        normalizeWorkTitle('Way Back Home'),
        normalizeWorkTitle('Way Back Home (feat. Conor Maynard)'),
      );
    });

    test('全角与半角标点等价', () {
      expect(
        normalizeWorkTitle('Hello，World'),
        normalizeWorkTitle('Hello,World'),
      );
      expect(normalizeWorkTitle('她说'), normalizeWorkTitle('她说 '));
    });

    test('大小写不敏感', () {
      expect(normalizeWorkTitle('Hello'), normalizeWorkTitle('HELLO'));
    });

    test('空输入返回空串而非抛异常', () {
      expect(normalizeWorkTitle(''), '');
      expect(normalizeWorkTitle('   '), '');
    });

    test('嵌套修饰括号被完全剥离', () {
      expect(
        normalizeWorkTitle('Song (Live) (Remastered)'),
        normalizeWorkTitle('Song'),
      );
    });
  });

  group('艺人归一化', () {
    test('多艺人顺序不同仍等价（渠道间最常见差异）', () {
      expect(normalizeWorkArtist('周杰伦/方文山'), normalizeWorkArtist('方文山/周杰伦'));
    });

    test('不同分隔符等价', () {
      expect(normalizeWorkArtist('A/B'), normalizeWorkArtist('A、B'));
      expect(normalizeWorkArtist('A & B'), normalizeWorkArtist('A,B'));
      expect(normalizeWorkArtist('A feat. B'), normalizeWorkArtist('A/B'));
    });

    test('重复艺人去重', () {
      expect(normalizeWorkArtist('A/A/B'), normalizeWorkArtist('A/B'));
    });

    test('空艺人返回空串', () {
      expect(normalizeWorkArtist(''), '');
      expect(normalizeWorkArtist('  '), '');
    });
  });

  group('WorkId 同一性判定（核心假设）', () {
    test('同一首歌跨渠道不同写法 → 同一个 WorkId', () {
      // 模拟四渠道对同一首歌的返回
      final netease = buildWorkId(
        title: '海阔天空',
        artist: 'Beyond',
        fallbackKey: 'netease:347230',
      );
      final qq = buildWorkId(
        title: '海阔天空 (Live)',
        artist: 'BEYOND',
        fallbackKey: 'qq:0039MnYb0qxYhV',
      );
      final kugou = buildWorkId(
        title: '海阔天空【伴奏】',
        artist: 'Beyond',
        fallbackKey: 'kugou:abc123',
      );

      expect(netease.matches(qq), isTrue, reason: '版本标注差异不应分裂作品');
      expect(netease.matches(kugou), isTrue);
      expect(qq.matches(kugou), isTrue);
      expect(netease.value, qq.value);
    });

    test('艺人顺序不同的同曲 → 同一个 WorkId', () {
      final a = buildWorkId(title: '不能说的秘密', artist: '周杰伦/方文山');
      final b = buildWorkId(title: '不能说的秘密', artist: '方文山、周杰伦');
      expect(a.matches(b), isTrue);
    });

    test('不同歌曲**绝不**被合并（宁可少合并，不可错合并）', () {
      final a = buildWorkId(title: '海阔天空', artist: 'Beyond');
      final b = buildWorkId(title: '光辉岁月', artist: 'Beyond');
      expect(a.matches(b), isFalse);

      // 同名不同歌手：绝不能合并
      final c = buildWorkId(title: '后来', artist: '刘若英');
      final d = buildWorkId(title: '后来', artist: '张敬轩');
      expect(c.matches(d), isFalse);
    });

    test('系列曲目的序号差异**不得**被合并（对抗性用例）', () {
      // 「(Part 1)」不是版本修饰而是标题的组成部分，剥离它会把
      // 交响曲 / 连续剧原声的不同乐章错误合并成一首。
      final part1 = buildWorkId(title: 'Symphony No.5 (Part 1)', artist: 'X');
      final part2 = buildWorkId(title: 'Symphony No.5 (Part 2)', artist: 'X');
      expect(part1.matches(part2), isFalse, reason: '序号不同是不同作品');
    });

    test('明确的编曲差异不被合并（钢琴版 / 器乐版）', () {
      // 「钢琴版」不在修饰白名单内，因此不会被剥离 → 不合并。
      // 这是刻意的保守取舍：宁可不合并，也不让用户听到非预期版本。
      final original = buildWorkId(title: '夜曲', artist: '周杰伦');
      final piano = buildWorkId(title: '夜曲（钢琴版）', artist: '周杰伦');
      expect(original.matches(piano), isFalse);
    });

    test('数字与字母差异不被标点归一化吞掉', () {
      final a = buildWorkId(title: 'Track 1', artist: 'X');
      final b = buildWorkId(title: 'Track 2', artist: 'X');
      expect(a.matches(b), isFalse);
    });

    test('ISRC 双方都有时以 ISRC 为准（标题差异不影响）', () {
      final a = buildWorkId(
        title: 'Song A',
        artist: 'X',
        isrc: 'US-ABC-12-34567',
      );
      final b = buildWorkId(
        title: '完全不同的标题',
        artist: 'Y',
        isrc: 'USABC1234567', // 同 ISRC，分隔符不同
      );
      expect(a.matches(b), isTrue, reason: 'ISRC 应统一去分隔符后比较');
    });

    test('一边有 ISRC 一边无 → 回退标题/艺人比较，不误判为不同', () {
      final withIsrc = buildWorkId(
        title: '海阔天空',
        artist: 'Beyond',
        isrc: 'HK-A00-93-00001',
      );
      final withoutIsrc = buildWorkId(title: '海阔天空', artist: 'Beyond');
      expect(
        withIsrc.matches(withoutIsrc),
        isTrue,
        reason: 'ISRC 缺失时不能直接判定为不同作品',
      );
    });

    test('ISRC 不同则判定为不同作品（即使标题相同）', () {
      final a = buildWorkId(title: 'Same', artist: 'X', isrc: 'AAAAAAAAAAA');
      final b = buildWorkId(title: 'Same', artist: 'X', isrc: 'BBBBBBBBBBB');
      expect(a.matches(b), isFalse);
    });

    test('空标题空艺人降级到 fallbackKey，不与其他空曲目混为一谈', () {
      final a = buildWorkId(title: '', artist: '', fallbackKey: 'netease:1');
      final b = buildWorkId(title: '', artist: '', fallbackKey: 'qq:2');
      expect(a.matches(b), isFalse, reason: '无法归一化时必须靠原始键区分，否则所有无标签曲目会合并');
      expect(a.value, contains('netease:1'));
    });

    test('完全无信息的输入也返回可用 WorkId，永不抛异常', () {
      expect(() => buildWorkId(title: '', artist: ''), returnsNormally);
      final id = buildWorkId(title: '', artist: '');
      expect(id.value, isNotEmpty);
    });
  });

  group('边界与鲁棒性', () {
    test('极长标题不抛异常', () {
      final long = 'A' * 5000;
      expect(() => buildWorkId(title: long, artist: 'X'), returnsNormally);
    });

    test('纯标点标题不抛异常', () {
      expect(() => buildWorkId(title: '!!!???', artist: 'X'), returnsNormally);
    });

    test('emoji 标题不抛异常', () {
      expect(() => buildWorkId(title: '🎵🎶', artist: '🎤'), returnsNormally);
    });

    test('中日韩文本正确处理（不被标点正则误伤）', () {
      final a = buildWorkId(title: '残酷な天使のテーゼ', artist: '高橋洋子');
      final b = buildWorkId(title: '残酷な天使のテーゼ ', artist: '高橋洋子');
      expect(a.matches(b), isTrue);
      expect(a.normalizedTitle, contains('残酷'));
    });

    test('value 可作为 Hive 键（不含分隔冲突）', () {
      final id = buildWorkId(title: 'A|B', artist: 'C');
      // 标题中的 | 已被标点正则剔除，不会与分隔符冲突
      expect(id.value.split('|').length, lessThanOrEqualTo(2));
    });
  });
}
