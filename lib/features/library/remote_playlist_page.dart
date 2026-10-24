import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart' show sourceRegistryProvider;
import '../../core/model/remote_playlist.dart';
import '../../core/theme/app_tokens.dart';
import '../player/player_notifier.dart';
import '../shared/widgets/track_cover.dart';
import '../shared/widgets/track_tile.dart';
import 'data/remote_playlists_provider.dart';
import '../player/open_player.dart';

/// 渠道账号歌单详情（只读 + 播放全部/单曲播放）。
///
/// 经 [RemotePlaylistCapable] 抽象取数，任何实现该能力的渠道通用。
///
/// 曲目同样走 Provider（而非 initState 里的 `FutureBuilder`）：原实现把
/// Future 存在 State 字段里，失败后没有任何重取路径，只能退出页面重进（B6）。
/// 换成 family Provider 后 `ref.invalidate` 即可原地重试，且与列表页
/// 共用同一套「三态 + 重试」渲染。
class RemotePlaylistPage extends ConsumerWidget {
  const RemotePlaylistPage({super.key, required this.playlist});

  final RemotePlaylist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(),
      body: ref
          .watch(remotePlaylistTracksProvider(playlist))
          .when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error:
                (error, _) => _TracksError(
                  message: remotePlaylistsErrorMessage(error),
                  onRetry:
                      () => ref.invalidate(
                        remotePlaylistTracksProvider(playlist),
                      ),
                ),
            data: (tracks) {
              if (tracks.isEmpty) {
                return const Center(child: Text('歌单是空的'));
              }
              final sourceName =
                  ref
                      .watch(sourceRegistryProvider)
                      .resolve(playlist.sourceId)
                      ?.displayName ??
                  playlist.sourceId;
              return Column(
                children: [
                  // 封面头：此前进来就是一串编号列表，看不出是哪个歌单
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        TrackCover(
                          coverUrl: playlist.coverUrl,
                          size: 96,
                          radius: 16,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                playlist.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '$sourceName · ${tracks.length} 首',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: scheme.onSurface.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Row(
                      children: [
                        const Spacer(),
                        IconButton(
                          tooltip: '随机播放',
                          onPressed: () {
                            ref
                                .read(playerNotifierProvider.notifier)
                                .shufflePlay(tracks);
                            openPlayerAfterPlay(context);
                          },
                          icon: const Icon(Icons.shuffle_rounded),
                        ),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTokens.accent,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            ref
                                .read(playerNotifierProvider.notifier)
                                .playQueue(tracks);
                            openPlayerAfterPlay(context);
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
                          leading: Text(
                            '${index + 1}',
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
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
                              color: scheme.onSurface.withValues(alpha: 0.55),
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (track.duration != null)
                                Text(
                                  '${track.duration!.inMinutes}:${(track.duration!.inSeconds % 60).toString().padLeft(2, '0')}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              // 云端歌单里的歌同样要能收藏 / 加入本地歌单 / 排队
                              IconButton(
                                tooltip: '更多',
                                visualDensity: VisualDensity.compact,
                                onPressed:
                                    () => showTrackActions(
                                      context,
                                      ref,
                                      track,
                                      includeFavorite: true,
                                    ),
                                icon: const Icon(
                                  Icons.more_vert_rounded,
                                  size: 20,
                                ),
                              ),
                            ],
                          ),
                          onLongPress:
                              () => showTrackActions(
                                context,
                                ref,
                                track,
                                includeFavorite: true,
                              ),
                          onTap: () {
                            ref
                                .read(playerNotifierProvider.notifier)
                                .playQueue(tracks, startIndex: index);
                            openPlayerAfterPlay(context);
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

/// 歌单曲目加载失败：给出原因与重试，而不是只能退出重进（B6）。
class _TracksError extends StatelessWidget {
  const _TracksError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 40,
              color: Theme.of(context).colorScheme.error.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppTokens.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
