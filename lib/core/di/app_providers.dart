import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/application/account_notifier.dart';
import '../../features/auth/data/account_repository.dart';
import '../../features/library/data/library_repository.dart';
import '../../features/player/audio_handler.dart';
import '../../features/search/data/search_history_repository.dart';
import '../source/music_source.dart';
import '../source/source_registry.dart';
import '../../sources/kugou/kugou_source.dart';
import '../../sources/local/local_file_source.dart';
import '../../sources/netease/netease_source.dart';
import '../../sources/qqmusic/qq_music_source.dart';
import '../../sources/ytm/youtube_music_source.dart';

/// 组合根（依赖注入）。
///
/// Hive Box 与 AudioHandler 必须在 main() 中先构建，
/// 再经 ProviderScope.overrides 注入；此处所有 throw 仅作未覆盖时的显式失败。

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  throw StateError('accountRepositoryProvider 必须在启动时 override');
});

final libraryRepositoryProvider = Provider<LibraryRepository>((ref) {
  throw StateError('libraryRepositoryProvider 必须在启动时 override');
});

final audioHandlerProvider = Provider<MusaicAudioHandler>((ref) {
  throw StateError('audioHandlerProvider 必须在启动时 override');
});

final searchHistoryRepositoryProvider = Provider<SearchHistoryRepository>((ref) {
  throw StateError('searchHistoryRepositoryProvider 必须在启动时 override');
});

/// 凭据读取器工厂：渠道实现通过它读取自己的凭据，而不接触存储细节。
typedef CredentialReaderFactory = CredentialReader Function(String sourceId);

final credentialReaderFactoryProvider = Provider<CredentialReaderFactory>(
  (ref) {
    final repository = ref.watch(accountRepositoryProvider);
    CredentialReader readerFor(String sourceId) =>
        () => repository.readCredentials(sourceId);
    return readerFor;
  },
);

/// 渠道注册中心（Master Plan §5.3：新渠道在此注册一行，UI 零改动）。
final sourceRegistryProvider = Provider<SourceRegistry>((ref) {
  final createCredentialReader =
      ref.watch(credentialReaderFactoryProvider);
  final registry = SourceRegistry();

  registry.register(
    LocalFileSource(
      credentialReader: createCredentialReader(LocalFileSource.id),
    ),
  );

  registry.register(
    QqMusicSource(
      credentialReader: createCredentialReader(QqMusicSource.id),
    ),
  );

  registry.register(
    KugouSource(
      credentialReader: createCredentialReader(KugouSource.id),
    ),
  );

  registry.register(
    YouTubeMusicSource(
      credentialReader: createCredentialReader(YouTubeMusicSource.id),
    ),
  );

  registry.register(
    NeteaseSource(
      credentialReader: createCredentialReader(NeteaseSource.id),
      onSessionExpired: () => ref
          .read(accountsProvider.notifier)
          .markExpiredIfLoggedIn(NeteaseSource.id),
    ),
  );

  return registry;
});
