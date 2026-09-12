import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/sources/ytm/ytm_lyrics_parser.dart';

/// YTM 歌词解析（V1.2 F6/I4-ytm 功能补全）。
void main() {
  group('extractCaptionTrackUrl', () {
    test('从 player 响应取首个 captionTracks.baseUrl', () {
      final root = <String, dynamic>{
        'captions': <String, dynamic>{
          'playerCaptionsTracklistRenderer': <String, dynamic>{
            'captionTracks': <dynamic>[
              <String, dynamic>{'baseUrl': 'https://example.com/timedtext?v=1'},
              <String, dynamic>{'baseUrl': 'https://example.com/second'},
            ],
          },
        },
      };
      expect(extractCaptionTrackUrl(root), 'https://example.com/timedtext?v=1');
    });

    test('缺失/空列表返回 null', () {
      expect(extractCaptionTrackUrl(null), isNull);
      expect(extractCaptionTrackUrl(<String, dynamic>{}), isNull);
      expect(
        extractCaptionTrackUrl(<String, dynamic>{
          'captions': <String, dynamic>{
            'playerCaptionsTracklistRenderer': <String, dynamic>{
              'captionTracks': <dynamic>[],
            },
          },
        }),
        isNull,
      );
    });

    test('结构漂移不抛异常', () {
      expect(
        () => extractCaptionTrackUrl(<String, dynamic>{'captions': 'oops'}),
        returnsNormally,
      );
      expect(
        extractCaptionTrackUrl(<String, dynamic>{'captions': 'oops'}),
        isNull,
      );
    });
  });

  group('extractTimedLyricsText', () {
    test('从 engagementPanels 取 lyricsData', () {
      final root = <String, dynamic>{
        'engagementPanels': <dynamic>[
          <String, dynamic>{'unrelated': true},
          <String, dynamic>{
            'lyrics': <String, dynamic>{
              'timedLyricsModel': <String, dynamic>{
                'lyricsData': '[00:01.00]第一行\n[00:05.00]第二行',
              },
            },
          },
        ],
      };
      expect(extractTimedLyricsText(root), '[00:01.00]第一行\n[00:05.00]第二行');
    });

    test('无歌词面板返回 null', () {
      expect(extractTimedLyricsText(null), isNull);
      expect(extractTimedLyricsText(<String, dynamic>{}), isNull);
      expect(
        extractTimedLyricsText(<String, dynamic>{
          'engagementPanels': <dynamic>[
            <String, dynamic>{'foo': 'bar'},
          ],
        }),
        isNull,
      );
    });
  });

  group('timedTextXmlToLrc', () {
    test('经典 transcript XML 转 LRC', () {
      const xml = '''
<transcript>
  <text start="1.23" dur="4.5">Hello world</text>
  <text start="65.5" dur="3.0">Second line</text>
</transcript>''';
      final lrc = timedTextXmlToLrc(xml);
      expect(lrc, isNotNull);
      expect(lrc, contains('[00:01.23]Hello world'));
      expect(lrc, contains('[01:05.50]Second line'));
    });

    test('srv3 XML（毫秒 + 内嵌 s 标签）转 LRC', () {
      const xml = '''
<timedtext>
  <body>
    <p t="1230" d="4500"><s>你好</s><s>世界</s></p>
    <p t="65000" d="3000"><s>第二行</s></p>
  </body>
</timedtext>''';
      final lrc = timedTextXmlToLrc(xml);
      expect(lrc, isNotNull);
      expect(lrc, contains('[00:01.23]你好世界'));
      expect(lrc, contains('[01:05.00]第二行'));
    });

    test('json3 events 转 LRC', () {
      const json = '''
{"events":[
  {"tStartMs":1000,"segs":[{"utf8":"Line one"}]},
  {"tStartMs":61000,"segs":[{"utf8":"Line two"}]}
]}''';
      final lrc = timedTextXmlToLrc(json);
      expect(lrc, isNotNull);
      expect(lrc, contains('[00:01.00]Line one'));
      expect(lrc, contains('[01:01.00]Line two'));
    });

    test('XML 实体被还原', () {
      const xml =
          '<transcript><text start="1.0" dur="2.0">A &amp; B &lt;C&gt;</text></transcript>';
      final lrc = timedTextXmlToLrc(xml);
      expect(lrc, contains('A & B <C>'));
    });

    test('空输入 / 无有效行返回 null', () {
      expect(timedTextXmlToLrc(''), isNull);
      expect(timedTextXmlToLrc('<transcript></transcript>'), isNull);
      expect(timedTextXmlToLrc('not xml at all'), isNull);
    });

    test('全空文本行被跳过', () {
      const xml = '''
<transcript>
  <text start="1.0" dur="1.0">   </text>
  <text start="2.0" dur="1.0">有效</text>
</transcript>''';
      final lrc = timedTextXmlToLrc(xml);
      expect(lrc, isNotNull);
      expect(lrc, isNot(contains('[00:01.00]')));
      expect(lrc, contains('[00:02.00]有效'));
    });

    test('时间戳格式补零正确（分钟 > 9）', () {
      const xml =
          '<transcript><text start="601.05" dur="1.0">late</text></transcript>';
      expect(timedTextXmlToLrc(xml), contains('[10:01.05]late'));
    });
  });
}
