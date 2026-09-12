import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/features/player/domain/stream_prefetcher.dart';

/// 播放地址预取（改进计划 P2）。
///
/// 预取是「纯优化」——它出错不该影响任何用户可见行为，命中则显著减少
/// 点歌延迟。因此测试重点在**边界与失效**，而非「能取到」：
/// 过期必须拒绝、一次性语义、换目标不串味、失败静默。
void main() {
  Track track(String id) =>
      Track(id: id, sourceId: 'fake', title: 't$id', artist: 'a');

  ResolvedStream stream(String url) => ResolvedStream(url: url);

  group('基本预取与命中', () {
    test('预取后 take 命中并返回同一结果', () async {
      final prefetcher = StreamPrefetcher(
        resolve: (t) async => stream('https://x/${t.id}'),
      );

      prefetcher.prefetch(track('1'));
      await prefetcher.settled;

      expect(prefetcher.hasEntry, isTrue);
      expect(prefetcher.take(track('1'))?.url, 'https://x/1');
    });

    test('take 是一次性的：第二次返回 null', () async {
      final prefetcher = StreamPrefetcher(
        resolve: (t) async => stream('https://x/${t.id}'),
      );
      prefetcher.prefetch(track('1'));
      await prefetcher.settled;

      expect(prefetcher.take(track('1')), isNotNull);
      expect(
        prefetcher.take(track('1')),
        isNull,
        reason: '签名 URL 用掉后不应复用，否则重播可能拿到已失效地址',
      );
      expect(prefetcher.hasEntry, isFalse);
    });

    test('take 不匹配的曲目返回 null，且不消耗已有结果', () async {
      final prefetcher = StreamPrefetcher(
        resolve: (t) async => stream('https://x/${t.id}'),
      );
      prefetcher.prefetch(track('1'));
      await prefetcher.settled;

      expect(prefetcher.take(track('2')), isNull);
      expect(prefetcher.take(track('1')), isNotNull, reason: '误取别的曲目不该消耗掉已有结果');
    });

    test('未预取时 take 返回 null（不是异常）', () {
      final prefetcher = StreamPrefetcher(resolve: (t) async => stream('u'));
      expect(prefetcher.take(track('1')), isNull);
    });
  });

  group('失效与过期', () {
    test('超过 maxAge 的结果被拒绝（宁可重新解析）', () async {
      final prefetcher = StreamPrefetcher(
        resolve: (t) async => stream('https://x/${t.id}'),
        maxAge: const Duration(milliseconds: 30),
      );
      prefetcher.prefetch(track('1'));
      await prefetcher.settled;

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(
        prefetcher.take(track('1')),
        isNull,
        reason: '渠道播放地址多为短时效签名，过期必须重新解析',
      );
    });

    test('过期后再次 prefetch 会重新解析（长曲目场景）', () async {
      var calls = 0;
      final prefetcher = StreamPrefetcher(
        resolve: (t) async {
          calls++;
          return stream('https://x/$calls');
        },
        maxAge: const Duration(milliseconds: 30),
      );

      prefetcher.prefetch(track('1'));
      await prefetcher.settled;
      expect(calls, 1);

      await Future<void>.delayed(const Duration(milliseconds: 60));

      // 已过期：应重新解析而不是直接返回
      expect(prefetcher.isFreshFor(track('1')), isFalse);
      prefetcher.prefetch(track('1'));
      await prefetcher.settled;
      expect(calls, 2, reason: '过期结果必须刷新，否则长曲目预取永远无效');
    });

    test('未过期时 isFreshFor 为真且不重复解析', () async {
      var calls = 0;
      final prefetcher = StreamPrefetcher(
        resolve: (t) async {
          calls++;
          return stream('https://x/$calls');
        },
      );

      prefetcher.prefetch(track('1'));
      await prefetcher.settled;

      expect(prefetcher.isFreshFor(track('1')), isTrue);
      prefetcher.prefetch(track('1'));
      await prefetcher.settled;
      expect(calls, 1);
    });

    test('invalidate 清空结果与在途状态', () async {
      final prefetcher = StreamPrefetcher(
        resolve: (t) async => stream('https://x/${t.id}'),
      );
      prefetcher.prefetch(track('1'));
      await prefetcher.settled;
      expect(prefetcher.hasEntry, isTrue);

      prefetcher.invalidate();

      expect(prefetcher.hasEntry, isFalse);
      expect(prefetcher.take(track('1')), isNull);
      expect(prefetcher.inFlightKey, isNull);
    });
  });

  group('并发与目标切换', () {
    test('同一目标重复预取不会重复解析', () async {
      var calls = 0;
      final prefetcher = StreamPrefetcher(
        resolve: (t) async {
          calls++;
          return stream('https://x/${t.id}');
        },
      );

      prefetcher.prefetch(track('1'));
      prefetcher.prefetch(track('1'));
      prefetcher.prefetch(track('1'));
      await prefetcher.settled;

      expect(calls, 1);
    });

    test('已就绪时不重复解析', () async {
      var calls = 0;
      final prefetcher = StreamPrefetcher(
        resolve: (t) async {
          calls++;
          return stream('https://x/${t.id}');
        },
      );

      prefetcher.prefetch(track('1'));
      await prefetcher.settled;
      prefetcher.prefetch(track('1'));
      await prefetcher.settled;

      expect(calls, 1);
    });

    test('切换目标后，旧目标的迟到结果不会覆盖新目标', () async {
      final gate1 = Completer<ResolvedStream?>();
      final prefetcher = StreamPrefetcher(
        resolve:
            (t) =>
                t.id == '1'
                    ? gate1.future
                    : Future<ResolvedStream?>.value(stream('https://x/2')),
      );

      prefetcher.prefetch(track('1')); // 挂起
      prefetcher.prefetch(track('2')); // 换目标
      await prefetcher.settled;

      expect(prefetcher.take(track('2'))?.url, 'https://x/2');

      // 旧目标这时才返回：必须被丢弃
      gate1.complete(stream('https://x/1'));
      await Future<void>.delayed(Duration.zero);

      expect(prefetcher.take(track('1')), isNull, reason: '迟到的旧目标结果不得污染当前预取');
    });
  });

  group('失败静默（预取只是优化）', () {
    test('解析抛异常不向外传播', () async {
      final prefetcher = StreamPrefetcher(
        resolve: (t) async => throw StateError('解析失败'),
      );

      prefetcher.prefetch(track('1'));
      await expectLater(prefetcher.settled, completes);

      expect(prefetcher.hasEntry, isFalse);
      expect(prefetcher.take(track('1')), isNull);
    });

    test('解析返回 null 视为未命中，不留下垃圾条目', () async {
      final prefetcher = StreamPrefetcher(resolve: (t) async => null);

      prefetcher.prefetch(track('1'));
      await prefetcher.settled;

      expect(prefetcher.hasEntry, isFalse);
    });

    test('失败后 inFlight 被清理，可重新预取', () async {
      var attempt = 0;
      final prefetcher = StreamPrefetcher(
        resolve: (t) async {
          attempt++;
          if (attempt == 1) throw StateError('首次失败');
          return stream('https://x/ok');
        },
      );

      prefetcher.prefetch(track('1'));
      await prefetcher.settled;
      expect(prefetcher.inFlightKey, isNull);

      prefetcher.prefetch(track('1'));
      await prefetcher.settled;
      expect(prefetcher.take(track('1'))?.url, 'https://x/ok');
    });
  });
}
