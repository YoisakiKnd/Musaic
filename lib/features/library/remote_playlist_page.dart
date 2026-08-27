import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/model/remote_playlist.dart';
import '../../core/model/track.dart';
import '../../core/source/capabilities.dart';
import '../../core/theme/app_tokens.dart';
import '../player/player_notifier.dart';

/// 渠道账号歌单详情（只读 + 播放全部/单曲播放）。
///
/// 经 [RemotePlaylistCapable] 抽象取数，任何实现该能力的渠道通用。
class RemotePlaylistPage extends ConsumerStatefulWidget {
  const RemotePlaylistPage({super.key, required this.playlist});

  final RemotePlaylist playlist;

  @override
  ConsumerState<RemotePlaylistPage> createState() =>
      _RemotePlaylistPageState();
}

class _RemotePlaylistPageState extends ConsumerState<RemotePlaylistPage> {
  late final Future<List<Track>> _tracksFuture;

  @override
  void initState() {
    super.initState();
    final source = ref
        .read(sourceRegistryProvider)
        .resolve(widget.playlist.sourceId);
    final capable = source is RemotePlaylistCapable
        ? source as RemotePlaylistCapable
        : null;
    _tracksFuture = capable?.fetchRemotePlaylistTracks(widget.playlist.id) ??
        Future<List<Track>>.value(const <Track>[]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.playlist.name)),
      body: FutureBuilder<List<Track>>(
        future: _tracksFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('加载失败：${snapshot.error}'));
          }
          final tracks = snapshot.data ?? const <Track>[];
          if (tracks.isEmpty) {
            return const Center(child: Text('歌单是空的'));
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    Text('${tracks.length} 首',
                        style: TextStyle(
                          fontSize: 13,
                          color:
                              scheme.onSurface.withValues(alpha: 0.6),
                        )),
                    const Spacer(),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTokens.accent,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () {
                        ref
                            .read(playerNotifierProvider.notifier)
                            .playQueue(tracks);
                        context.push('/player');
                      },
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('播放全部'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 120),
                  itemCount: tracks.length,
                  itemBuilder: (context, index) {
                    final track = tracks[index];
                    return ListTile(
                      dense: true,
                      leading: Text('${index + 1}',
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurface
                                .withValues(alpha: 0.5),
                          )),
                      title: Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              scheme.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                      trailing: track.duration != null
                          ? Text(
                              '${track.duration!.inMinutes}:${(track.duration!.inSeconds % 60).toString().padLeft(2, '0')}',
                              style: const TextStyle(fontSize: 12),
                            )
                          : null,
                      onTap: () {
                        ref
                            .read(playerNotifierProvider.notifier)
                            .playQueue(tracks, startIndex: index);
                        context.push('/player');
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
