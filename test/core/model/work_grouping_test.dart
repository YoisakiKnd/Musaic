import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/model/work_grouping.dart';

/// 跨渠道换源候选分组（日常可用性计划 D7 / 设计文档 §2.3）。
///
/// 设计取巧点：换源候选**不需要额外请求**——搜索结果里同一首歌
/// 往往已经带着多个渠道的记录，用 WorkId 认出来即可。
void main() {
  Track on(String sourceId, String id, {String? title, String? artist}) =>
      Track(
        id: id,
        sourceId: sourceId,
        title: title ?? '海阔天空',
        artist: artist ?? 'Beyond',
      );

  group('buildAlternatives', () {
    test('同一首歌的多渠道记录互为替代', () {
      final tracks = [
        on('netease', '347230'),
        on('qqmusic', '0039MnYb0qxYhV'),
        on('kugou', 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6'),
      ];

      final map = buildAlternatives(tracks);

      expect(map, hasLength(3), reason: '三条记录都应有替代候选');
      expect(map['netease:347230']!.map((t) => t.sourceId), [
        'qqmusic',
        'kugou',
      ]);
      expect(map['qqmusic:0039MnYb0qxYhV']!.map((t) => t.sourceId), [
        'netease',
        'kugou',
      ]);
    });

    test('替代列表不包含曲目自身', () {
      final tracks = [on('netease', '1'), on('qqmusic', '2')];
      final map = buildAlternatives(tracks);
      for (final entry in map.entries) {
        expect(
          entry.value.map((t) => t.key),
          isNot(contains(entry.key)),
          reason: '自身不应出现在自己的替代列表里',
        );
      }
    });

    test('单渠道曲目不出现在结果中（避免无意义查表）', () {
      final tracks = [
        on('netease', '1', title: '独一无二'),
        on('qqmusic', '2', title: '海阔天空'),
        on('kugou', '3', title: '海阔天空'),
      ];

      final map = buildAlternatives(tracks);

      expect(map.containsKey('netease:1'), isFalse);
      expect(map.containsKey('qqmusic:2'), isTrue);
      expect(map.containsKey('kugou:3'), isTrue);
    });

    test('不同歌曲不会被归为一组', () {
      final tracks = [
        on('netease', '1', title: '海阔天空'),
        on('qqmusic', '2', title: '光辉岁月'),
      ];
      expect(buildAlternatives(tracks), isEmpty);
    });

    test('同名不同歌手不会被归为一组', () {
      final tracks = [
        on('netease', '1', title: '后来', artist: '刘若英'),
        on('qqmusic', '2', title: '后来', artist: '张敬轩'),
      ];
      expect(buildAlternatives(tracks), isEmpty);
    });

    test('版本后缀差异仍能识别为同一作品', () {
      final tracks = [
        on('netease', '1', title: '海阔天空'),
        on('qqmusic', '2', title: '海阔天空 (Live)'),
      ];
      final map = buildAlternatives(tracks);
      expect(map, hasLength(2));
      expect(map['netease:1']!.single.sourceId, 'qqmusic');
    });

    test('空列表与单条列表返回空 Map', () {
      expect(buildAlternatives(const <Track>[]), isEmpty);
      expect(buildAlternatives([on('netease', '1')]), isEmpty);
    });

    test('三条以上记录时每条的替代都含其余全部', () {
      final tracks = [
        on('netease', '1'),
        on('qqmusic', '2'),
        on('kugou', '3'),
        on('ytm', 'dQw4w9WgXcQ'),
      ];
      final map = buildAlternatives(tracks);
      expect(map, hasLength(4));
      for (final alternatives in map.values) {
        expect(alternatives, hasLength(3));
      }
    });
  });

  group('orderFallbackCandidates', () {
    test('排除刚失败的渠道（避免原地重试）', () {
      final alternatives = [
        on('netease', '1'),
        on('qqmusic', '2'),
        on('kugou', '3'),
      ];

      final ordered = orderFallbackCandidates(
        alternatives: alternatives,
        failedSourceId: 'netease',
      );

      expect(ordered.map((t) => t.sourceId), ['qqmusic', 'kugou']);
    });

    test('排除本地文件（避免在线曲目回退到同名本地文件）', () {
      final alternatives = [on('local', '/music/x.flac'), on('qqmusic', '2')];

      final ordered = orderFallbackCandidates(
        alternatives: alternatives,
        failedSourceId: 'netease',
      );

      expect(ordered.map((t) => t.sourceId), ['qqmusic']);
    });

    test('全是本地文件时仍允许回退（总比直接报错好）', () {
      final alternatives = [on('local', '/a.flac'), on('local', '/b.flac')];

      final ordered = orderFallbackCandidates(
        alternatives: alternatives,
        failedSourceId: 'netease',
      );

      expect(ordered, hasLength(2));
    });

    test('全部被排除时返回空列表（调用方据此直接报错）', () {
      final alternatives = [on('netease', '1')];
      final ordered = orderFallbackCandidates(
        alternatives: alternatives,
        failedSourceId: 'netease',
      );
      expect(ordered, isEmpty);
    });

    test('保持传入顺序（即渠道优先级）', () {
      final alternatives = [
        on('qqmusic', '2'),
        on('kugou', '3'),
        on('ytm', 'v'),
      ];
      final ordered = orderFallbackCandidates(
        alternatives: alternatives,
        failedSourceId: 'netease',
      );
      expect(ordered.map((t) => t.sourceId), ['qqmusic', 'kugou', 'ytm']);
    });
  });
}
