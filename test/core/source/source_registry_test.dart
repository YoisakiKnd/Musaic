import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/auth/auth_capability.dart';

class _StubSource extends MusicSource {
  _StubSource(this._id, this._name) : super(credentialReader: _noopReader);

  final String _id;
  final String _name;

  @override
  String get sourceId => _id;
  @override
  String get displayName => _name;
  @override
  AuthCapability get authCapability => AuthCapability.noAuth;

  @override
  Future<List<Track>> search(String query,
          {int limit = 30, int offset = 0}) async =>
      const [];
  @override
  Future<Track> getTrackDetail(Track track) => throw UnimplementedError();
  @override
  Future<ResolvedStream> resolveStream(Track track) =>
      throw UnimplementedError();
  @override
  Future<LyricBundle?> fetchLyrics(Track track) => throw UnimplementedError();
}

Future<Map<String, String>> _noopReader() async => <String, String>{};

void main() {
  test('注册后可按 sourceId 解析', () {
    final registry = SourceRegistry()
      ..register(_StubSource('local', '本地文件'))
      ..register(_StubSource('netease', '网易云音乐'));

    expect(registry.length, 2);
    expect(registry.resolve('netease')?.displayName, '网易云音乐');
    expect(registry.resolve('local')?.displayName, '本地文件');
    expect(registry.contains('netease'), isTrue);
    expect(registry.contains('missing'), isFalse);
  });

  test('未解析返回 null', () {
    final registry = SourceRegistry();
    expect(registry.resolve('none'), isNull);
  });

  test('重复注册覆盖且顺序保持首次插入位置', () {
    final registry = SourceRegistry()
      ..register(_StubSource('a', 'A1'))
      ..register(_StubSource('b', 'B'))
      ..register(_StubSource('a', 'A2'));

    expect(registry.resolve('a')?.displayName, 'A2');
    expect(registry.all.map((s) => s.sourceId), ['a', 'b']);
  });

  test('注销渠道后不可再解析', () {
    final registry = SourceRegistry()..register(_StubSource('a', 'A'));
    registry.unregister('a');
    expect(registry.resolve('a'), isNull);
    expect(registry.all, isEmpty);
  });
}
