import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/model/track.dart';

void main() {
  group('Track', () {
    test('fromJson should create Track', () {
      final track = Track.fromJson({
        'id': '123',
        'sourceId': 'netease',
        'title': 'Test Song',
        'artist': 'Test Artist',
        'album': 'Test Album',
        'duration': 240000,
        'coverUrl': 'https://example.com/cover.jpg',
      });

      expect(track.id, '123');
      expect(track.sourceId, 'netease');
      expect(track.title, 'Test Song');
      expect(track.artist, 'Test Artist');
      expect(track.album, 'Test Album');
      expect(track.duration, const Duration(minutes: 4));
      expect(track.coverUrl, 'https://example.com/cover.jpg');
    });

    test('toJson should produce correct map', () {
      const track = Track(
        id: '123',
        sourceId: 'local',
        title: 'Test',
        artist: 'Artist',
      );

      final json = track.toJson();
      expect(json['id'], '123');
      expect(json['sourceId'], 'local');
      expect(json['title'], 'Test');
      expect(json['artist'], 'Artist');
    });

    test('copyWith should update fields', () {
      const track = Track(
        id: '1',
        sourceId: 'local',
        title: 'A',
        artist: 'B',
      );

      final updated = track.copyWith(title: 'C');
      expect(updated.title, 'C');
      expect(updated.artist, 'B');
    });

    test('equality should work', () {
      const track1 = Track(id: '1', sourceId: 'local', title: 'A', artist: 'B');
      const track2 = Track(id: '1', sourceId: 'local', title: 'A', artist: 'B');
      const track3 = Track(id: '2', sourceId: 'local', title: 'A', artist: 'B');

      expect(track1, equals(track2));
      expect(track1, isNot(equals(track3)));
    });
  });
}
