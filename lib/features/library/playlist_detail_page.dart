import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_tokens.dart';
import '../player/player_notifier.dart';
import '../shared/widgets/track_tile.dart';

/// 歌单详情（Master Plan P6）：播放全部 / 移除单曲。
class PlaylistDetailPage extends ConsumerWidget {
  const PlaylistDetailPage({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(libraryRepositoryProvider);
    final tracks = repository.playlistTracks(name);

    return Scaffold(
      appBar: AppBar(title: Text(name)),
      floatingActionButton: tracks.isEmpty
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AppTokens.accent,
              foregroundColor: Colors.white,
              onPressed: () {
                ref
                    .read(playerNotifierProvider.notifier)
                    .playQueue(tracks);
                context.push('/player');
              },
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('播放全部'),
            ),
      body: tracks.isEmpty
          ? Center(
              child: Text('歌单还是空的，去搜索页添加歌曲吧',
                  style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.55),
                  )),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: tracks.length,
              itemBuilder: (context, index) => TrackTile(
                track: tracks[index],
                queue: tracks,
                onRemove: () =>
                    repository.removeFromPlaylist(name, index),
              ),
            ),
    );
  }
}

