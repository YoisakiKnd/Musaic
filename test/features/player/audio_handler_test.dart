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
}
