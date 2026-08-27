import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/application/account_notifier.dart';
import '../../features/auth/data/account_repository.dart';
import '../../features/library/data/library_repository.dart';
import '../../features/player/audio_handler.dart';
import '../../features/search/data/search_history_repository.dart';
import '../../features/settings/data/local_music_settings_repository.dart';
import '../../features/settings/settings_providers.dart'
    show audioQualityProvider, AudioQualityBits;
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

/// 会话过期回调工厂：把每个渠道网络层的被动捕获统一接到
/// [AccountNotifier.markExpiredIfLoggedIn]。
/// 所有需要过期感知的渠道都必须经它注入，
/// 杜绝历史上「只给单一渠道接了回调」的不对称缺陷。
void Function() expiredCallbackFor(Ref ref, String sourceId) =>
    () => ref.read(accountsProvider.notifier).markExpiredIfLoggedIn(sourceId);

/// 渠道注册中心（Master Plan §5.3：新渠道在此注册一行，UI 零改动）。
final sourceRegistryProvider = Provider<SourceRegistry>((ref) {
  final createCredentialReader =
      ref.watch(credentialReaderFactoryProvider);
  final registry = SourceRegistry();

  registry.register(
    LocalFileSource(
      credentialReader: createCredentialReader(LocalFileSource.id),
      // 用户在「设置 → 本地音乐」添加的文件夹优先；未配置时回退默认目录
      directoryProvider: () async {
        final settings = ref.read(localMusicSettingsRepositoryProvider);
        final userDirs = settings.folders
            .map(Directory.new)
            .where((dir) => dir.existsSync())
            .toList(growable: false);
        if (userDirs.isNotEmpty) return userDirs;
        return LocalFileSource.defaultDirectories();
      },
    ),
  );

  registry.register(
    QqMusicSource(
      credentialReader: createCredentialReader(QqMusicSource.id),
      onSessionExpired: expiredCallbackFor(ref, QqMusicSource.id),
    ),
  );

  registry.register(
    KugouSource(
      credentialReader: createCredentialReader(KugouSource.id),
      onSessionExpired: expiredCallbackFor(ref, KugouSource.id),
    ),
  );

  registry.register(
    YouTubeMusicSource(
      credentialReader: createCredentialReader(YouTubeMusicSource.id),
      onSessionExpired: expiredCallbackFor(ref, YouTubeMusicSource.id),
      // 音质档位 → googlevideo 码率上限（读取时求值，不触发 registry 重建）
      maxBitrateProvider: () =>
          ref.read(audioQualityProvider).ytmMaxBitrate,
    ),
  );

  registry.register(
    NeteaseSource(
      credentialReader: createCredentialReader(NeteaseSource.id),
      onSessionExpired: expiredCallbackFor(ref, NeteaseSource.id),
      // 音质档位 → weapi br 参数
      bitrateProvider: () => ref.read(audioQualityProvider).neteaseBr,
    ),
  );

  return registry;
});
