import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/model/track.dart';

Track _sample() => const Track(
      id: '186016',
      sourceId: 'netease',
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      duration: Duration(milliseconds: 269546),
      coverUrl: 'https://example.com/cover.jpg',
      sourceData: {'neteaseId': 186016},
    );

void main() {
  test('key 由渠道与曲目 id 组成', () {
    expect(_sample().key, 'netease:186016');
  });

  test('toJson/fromJson 往返一致（含 sourceData）', () {
    final track = _sample();
    final restored = Track.fromJson(track.toJson());
    expect(restored, equals(track));
    expect(restored.album, '叶惠美');
    expect(restored.duration, const Duration(milliseconds: 269546));
    expect(restored.sourceData?['neteaseId'], 186016);
  });

  test('可空字段省略序列化且恢复为 null', () {
    const minimal = Track(id: 'f1', sourceId: 'local', title: 'T', artist: 'A');
    final json = minimal.toJson();
    expect(json.containsKey('album'), isFalse);
    expect(json.containsKey('coverUrl'), isFalse);
    final restored = Track.fromJson(json);
    expect(restored.coverUrl, isNull);
    expect(restored.duration, isNull);
  });

  test('相等性基于 key，与 sourceData 无关', () {
    final a = _sample();
    final b = _sample().copyWith(coverUrl: 'https://other.jpg');
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode);
  });

  test('copyWith 可将字段显式置空', () {
    final cleared = _sample().copyWith(
      album: null,
      coverUrl: null,
      duration: null,
    );
    expect(cleared.album, isNull);
    expect(cleared.coverUrl, isNull);
    expect(cleared.duration, isNull);
    // 未触碰字段保持不变
    expect(cleared.title, '晴天');
  });

  test('toString 不泄漏敏感信息', () {
    final text = _sample().toString();
    expect(text.contains('https://'), isFalse);
  });
}
