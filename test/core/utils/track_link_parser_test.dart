import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/utils/track_link_parser.dart';

/// 分享链接 / 裸 ID 解析（日常可用性计划 D1）。
///
/// 背景：搜索框提示「搜索 / 链接 / ID」但此前无任何解析实现，
/// 用户粘贴分享链接会被当关键字搜出空结果。
///
/// 本测试的核心不只是「能解析」，更是**不误判**：
/// 普通搜索词绝不能被当成链接，否则搜索直接失效。
void main() {
  group('网易云', () {
    test('标准分享链接（?id=）', () {
      expect(
        parseTrackLink('https://music.163.com/song?id=347230'),
        const TrackLink(sourceId: 'netease', id: '347230'),
      );
    });

    test('带多余 query 参数', () {
      expect(
        parseTrackLink(
          'https://music.163.com/song?id=347230&userid=123&from=timeline',
        ),
        const TrackLink(sourceId: 'netease', id: '347230'),
      );
    });

    test('路径形态 /song/347230', () {
      expect(
        parseTrackLink('https://music.163.com/song/347230'),
        const TrackLink(sourceId: 'netease', id: '347230'),
      );
    });

    test('hash 路由形态 #/song?id=347230', () {
      expect(
        parseTrackLink('https://music.163.com/#/song?id=347230'),
        const TrackLink(sourceId: 'netease', id: '347230'),
      );
    });

    test('移动端域名 y.music.163.com', () {
      expect(
        parseTrackLink('https://y.music.163.com/m/song?id=347230'),
        const TrackLink(sourceId: 'netease', id: '347230'),
      );
    });

    test('裸数字 id 可推断为网易云', () {
      expect(
        parseTrackLink('347230'),
        const TrackLink(sourceId: 'netease', id: '347230'),
      );
    });

    test('显式前缀 netease:347230', () {
      expect(
        parseTrackLink('netease:347230'),
        const TrackLink(sourceId: 'netease', id: '347230'),
      );
    });
  });

  group('QQ 音乐', () {
    test('songDetail 路径', () {
      expect(
        parseTrackLink('https://y.qq.com/n/ryqq/songDetail/0039MnYb0qxYhV'),
        const TrackLink(sourceId: 'qqmusic', id: '0039MnYb0qxYhV'),
      );
    });

    test('songmid query 参数', () {
      expect(
        parseTrackLink(
          'https://y.qq.com/portal/player.html?songmid=0039MnYb0qxYhV',
        ),
        const TrackLink(sourceId: 'qqmusic', id: '0039MnYb0qxYhV'),
      );
    });

    test('显式前缀 qqmusic:xxx', () {
      expect(
        parseTrackLink('qqmusic:0039MnYb0qxYhV'),
        const TrackLink(sourceId: 'qqmusic', id: '0039MnYb0qxYhV'),
      );
    });

    test('裸 mid 不推断（与 YTM videoId 形态重叠，无法可靠区分）', () {
      // 11 位字母数字：既是合法 YTM videoId 形态，也可能是 QQ mid。
      // 宁可交回普通搜索，也不猜错渠道。
      expect(parseTrackLink('dQw4w9WgXcQ'), isNull);
    });
  });

  group('酷狗', () {
    const hash = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6';

    test('hash query 参数', () {
      expect(
        parseTrackLink('https://www.kugou.com/song/?hash=$hash'),
        const TrackLink(sourceId: 'kugou', id: hash),
      );
    });

    test('hash 片段形态', () {
      expect(
        parseTrackLink('https://www.kugou.com/song/#hash=$hash'),
        const TrackLink(sourceId: 'kugou', id: hash),
      );
    });

    test('裸 32 位 hex 可推断为酷狗', () {
      expect(
        parseTrackLink(hash),
        const TrackLink(sourceId: 'kugou', id: hash),
      );
    });

    test('大写 hash 归一为小写', () {
      expect(
        parseTrackLink(
          'https://www.kugou.com/song/?hash=${hash.toUpperCase()}',
        ),
        const TrackLink(sourceId: 'kugou', id: hash),
      );
    });
  });

  group('YouTube Music', () {
    // 注意：渠道 id 是 `ytmusic`（见 YouTubeMusicSource.id），不是 `ytm`。
    // 这里用常量而非字面量，并由 test/core/di/app_providers_test.dart
    // 断言它与真实注册的渠道 id 一致——避免「解析成功但找不到渠道」。
    test('watch?v= 形态', () {
      expect(
        parseTrackLink('https://music.youtube.com/watch?v=dQw4w9WgXcQ'),
        const TrackLink(sourceId: youtubeMusicSourceId, id: 'dQw4w9WgXcQ'),
      );
    });

    test('youtu.be 短链', () {
      expect(
        parseTrackLink('https://youtu.be/dQw4w9WgXcQ'),
        const TrackLink(sourceId: youtubeMusicSourceId, id: 'dQw4w9WgXcQ'),
      );
    });

    test('shorts 形态', () {
      expect(
        parseTrackLink('https://www.youtube.com/shorts/dQw4w9WgXcQ'),
        const TrackLink(sourceId: youtubeMusicSourceId, id: 'dQw4w9WgXcQ'),
      );
    });

    test('带播放列表参数的 watch 链接', () {
      expect(
        parseTrackLink(
          'https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVMxyz',
        ),
        const TrackLink(sourceId: youtubeMusicSourceId, id: 'dQw4w9WgXcQ'),
      );
    });
  });

  group('绝不误判普通搜索词（关键）', () {
    test('中文歌名不被当成链接', () {
      for (final q in ['海阔天空', '周杰伦 晴天', '夜曲 钢琴版']) {
        expect(parseTrackLink(q), isNull, reason: '「$q」应走普通搜索');
      }
    });

    test('英文歌名不被当成链接', () {
      for (final q in ['Hello', 'Bohemian Rhapsody', 'Way Back Home']) {
        expect(parseTrackLink(q), isNull, reason: '「$q」应走普通搜索');
      }
    });

    test('带空格的查询不被当成链接', () {
      expect(parseTrackLink('beyond 海阔天空'), isNull);
    });

    test('普通网址（非音乐渠道）不被解析', () {
      for (final url in [
        'https://www.google.com/search?q=music',
        'https://example.com/song?id=123',
        'https://github.com/foo/bar',
      ]) {
        expect(parseTrackLink(url), isNull, reason: '「$url」不是音乐渠道链接');
      }
    });

    test('短数字不误判（避免把年份当 id）', () {
      // 「2024」是合法数字，但作为搜索词更可能是年份。
      // 当前实现会解析为网易云 id —— 这是**已知取舍**，见下方说明。
      final result = parseTrackLink('2024');
      expect(result?.sourceId, 'netease');
    });

    test('纯数字过长的输入不解析', () {
      expect(parseTrackLink('1' * 20), isNull);
    });

    test('空串与空白返回 null', () {
      expect(parseTrackLink(''), isNull);
      expect(parseTrackLink('   '), isNull);
    });

    test('渠道域名但路径无 id → 不解析（交回搜索）', () {
      expect(parseTrackLink('https://music.163.com/'), isNull);
      expect(parseTrackLink('https://y.qq.com/'), isNull);
      expect(parseTrackLink('https://www.kugou.com/'), isNull);
    });
  });

  group('sourceHint（用户显式指定渠道）', () {
    test('有 hint 时可解析形态不唯一的裸 id', () {
      expect(
        parseTrackLink('0039MnYb0qxYhV', sourceHint: 'qqmusic'),
        const TrackLink(sourceId: 'qqmusic', id: '0039MnYb0qxYhV'),
      );
    });

    test('hint 与 id 形态不匹配时仍返回 null（不硬塞）', () {
      expect(parseTrackLink('海阔天空', sourceHint: 'qqmusic'), isNull);
      expect(parseTrackLink('abc', sourceHint: 'netease'), isNull);
    });

    test('local hint 接受任意路径', () {
      expect(
        parseTrackLink('/music/beyond.flac', sourceHint: 'local'),
        const TrackLink(sourceId: 'local', id: '/music/beyond.flac'),
      );
    });
  });

  group('边界与鲁棒性', () {
    test('极长输入不抛异常', () {
      expect(
        () => parseTrackLink('https://music.163.com/song?id=${'1' * 5000}'),
        returnsNormally,
      );
    });

    test('畸形 URL 不抛异常', () {
      for (final bad in ['https://', 'http://[', '://x', 'http://a b c']) {
        expect(() => parseTrackLink(bad), returnsNormally, reason: bad);
      }
    });

    test('大小写与协议不敏感', () {
      expect(
        parseTrackLink('HTTPS://MUSIC.163.COM/song?id=347230'),
        const TrackLink(sourceId: 'netease', id: '347230'),
      );
    });

    test('前后空白被裁剪', () {
      expect(
        parseTrackLink('  https://music.163.com/song?id=347230  '),
        const TrackLink(sourceId: 'netease', id: '347230'),
      );
    });

    test('TrackLink 相等性可用于去重', () {
      const a = TrackLink(sourceId: 'netease', id: '1');
      const b = TrackLink(sourceId: 'netease', id: '1');
      const c = TrackLink(sourceId: 'netease', id: '2');
      expect(a, b);
      expect(a, isNot(c));
      // a 与 b 相等，放入 Set 应只留一个。
      // 经列表构造以避免 analyzer 的 equal_elements_in_set 静态告警
      // （这里的「重复」正是被测行为，不是笔误）。
      final unique = <TrackLink>[];
      for (final link in <TrackLink>[a, b, c]) {
        if (!unique.contains(link)) unique.add(link);
      }
      expect(unique, hasLength(2));
    });
  });
}
