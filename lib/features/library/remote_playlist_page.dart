import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_tokens.dart';
import '../../sources/netease/netease_source.dart';
import '../player/player_notifier.dart';

/// 网易云账号歌单详情（只读 + 播放全部/单曲播放）。
class RemotePlaylistPage extends ConsumerStatefulWidget {
  const RemotePlaylistPage({super.key, required this.playlist});

  final NeteaseUserPlaylist playlist;

  @override
  ConsumerState<RemotePlaylistPage> createState() =>
      _RemotePlaylistPageState();
}

class _RemotePlaylistPageState extends ConsumerState<RemotePlaylistPage> {
  late final Future<List<dynamic>> _tracksFuture;

  @override
  void initState() {
    super.initState();
    final source = ref.read(sourceRegistryProvider).resolve('netease')
        as NeteaseSource?;
    _tracksFuture = source?.fetchPlaylistTracks(widget.playlist.id) ??
        Future.value(const []);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.playlist.name)),
      body: FutureBuilder<List<dynamic>>(
        future: _tracksFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('加载失败：${snapshot.error}'));
          }
          final tracks = snapshot.data ?? const [];
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
                            .playQueue(
                              tracks.cast(),
                            );
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
                  itemCount: tracks.length,
                  itemBuilder: (context, index) {
                    final track = tracks[index] as dynamic;
                    return ListTile(
                      dense: true,
                      leading: Text('${index + 1}',
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurface
                                .withValues(alpha: 0.5),
                          )),
                      title: Text(
                        track.title as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        track.artist as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              scheme.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                      trailing: (track.duration as Duration?) != null
                          ? Text(
                              '${(track.duration as Duration).inMinutes}:${((track.duration as Duration).inSeconds.remainder(60)).toString().padLeft(2, '0')}',
                              style: const TextStyle(fontSize: 12),
                            )
                          : null,
                      onTap: () {
                        ref
                            .read(playerNotifierProvider.notifier)
                            .playQueue(
                              tracks.cast(),
                              startIndex: index,
                            );
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
