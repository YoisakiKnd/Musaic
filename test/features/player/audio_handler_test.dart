import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musaic/features/player/audio_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AudioPlayer player;
  late MusaicAudioHandler handler;

  setUp(() {
    player = AudioPlayer();
    handler = MusaicAudioHandler(player: player);
  });

  tearDown(() async {
    await player.dispose();
  });

  test('publishQueue publishes the current queue index', () {
    handler.publishQueue(const [
      MediaItem(id: 'netease:1', title: 'One', artist: 'Artist'),
      MediaItem(id: 'netease:2', title: 'Two', artist: 'Artist'),
    ], queueIndex: 1);

    expect(handler.queue.value, hasLength(2));
    expect(handler.playbackState.value.queueIndex, 1);
  });

  test('publishQueue clears an invalid queue index', () {
    handler.publishQueue(const [
      MediaItem(id: 'netease:1', title: 'One', artist: 'Artist'),
    ], queueIndex: 3);

    expect(handler.playbackState.value.queueIndex, -1);
  });

  group('removeQueueItem 转发（P1 回归）', () {
    test('传入 MediaItem 时转发的是 id 而非 toString', () async {
      final removed = <String>[];
      handler.onRemoveQueueTrack = (key) async => removed.add(key);

      await handler.removeQueueItem(
        const MediaItem(id: 'netease:42', title: 'X', artist: 'Y'),
      );

      expect(removed, [
        'netease:42',
      ], reason: 'MediaItem.toString() 是整包 Map 序列化，与 track.key 永不相等');
    });

    test('传入 String key 时原样转发', () async {
      final removed = <String>[];
      handler.onRemoveQueueTrack = (key) async => removed.add(key);

      await handler.removeQueueItem('netease:7');

      expect(removed, ['netease:7']);
    });

    test('null 与空串不触发回调', () async {
      var calls = 0;
      handler.onRemoveQueueTrack = (_) async => calls++;

      await handler.removeQueueItem(null);
      await handler.removeQueueItem('');

      expect(calls, 0);
    });
  });
}
