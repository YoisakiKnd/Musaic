import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/model/track.dart';

class _MockSource extends MusicSource {
  @override
  String get sourceId => 'mock';

  @override
  String get sourceName => 'Mock';

  @override
  Future<List<Track>> search(String query) async => [];

  @override
  Future<Track> getTrackDetail(Track track) async => track;

  @override
  Future<String> getStreamUrl(Track track) async => 'https://example.com';

  @override
  Future<String?> getLyrics(Track track) async => null;
}

void main() {
  group('SourceRegistry', () {
    test('register and resolve should work', () {
      final registry = SourceRegistry();
      final source = _MockSource();

      registry.register(source);
      expect(registry.resolve('mock'), source);
    });

    test('resolve unknown source should return null', () {
      final registry = SourceRegistry();
      expect(registry.resolve('unknown'), isNull);
    });

    test('registerAll should add multiple sources', () {
      final registry = SourceRegistry();
      final source1 = _MockSource();
      final source2 = _MockSource()..sourceId;

      registry.registerAll([source1]);
      expect(registry.all.length, 1);
    });
  });
}
