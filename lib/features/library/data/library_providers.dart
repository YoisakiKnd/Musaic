import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/model/track.dart';

/// 资料库响应式 Provider：基于 Hive Box 事件流的本地优先状态。

final favoritesProvider = StreamProvider<List<Track>>((ref) {
  final repository = ref.watch(libraryRepositoryProvider);
  return repository
      .watchFavorites()
      .map((_) => repository.favorites);
});

final recentHistoryProvider = StreamProvider<List<Track>>((ref) {
  final repository = ref.watch(libraryRepositoryProvider);
  return repository.watchHistory().map((_) => repository.recentHistory());
});

final playlistsProvider = StreamProvider<List<String>>((ref) {
  final repository = ref.watch(libraryRepositoryProvider);
  return repository.watchPlaylists().map((_) => repository.playlistNames);
});
