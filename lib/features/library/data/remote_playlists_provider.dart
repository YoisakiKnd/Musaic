import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/source_account.dart';
import '../../../core/di/app_providers.dart';
import '../../../core/error/source_exception.dart';
import '../../../core/model/remote_playlist.dart';
import '../../../core/model/track.dart';
import '../../../core/source/capabilities.dart';
import '../../auth/application/account_notifier.dart';

/// 指定渠道的账号歌单（渠道需实现 [RemotePlaylistCapable]）。
///
/// 三态由 [AsyncValue] 承载，**失败不再被吞成空态**（B6）：
/// - `loading` 拉取中；
/// - `error` 拉取失败，[AsyncError.error] 即渠道抛出的原始异常；
/// - `data` 成功；未登录 / 渠道不支持该能力时是**空列表**（不是失败）。
///
/// 消费方用 `ref.invalidate(remotePlaylistsProvider(id))` 重试。
/// 账号状态变化自动重取。
final remotePlaylistsProvider =
    FutureProvider.family<List<RemotePlaylist>, String>((ref, sourceId) async {
      final capable = ref.watch(remotePlaylistCapableProvider(sourceId));
      if (capable == null) return const <RemotePlaylist>[];
      final account = ref.watch(sourceAccountProvider(sourceId));
      return capable.fetchRemotePlaylists(account.userId ?? '');
    });

/// 该渠道当前可用的账号歌单能力（未登录 / 渠道不支持时为 null）。
///
/// 单独暴露的原因：加载态不能无条件渲染。未登录 / 渠道不支持时
/// [remotePlaylistsProvider] 同样有一段 async 空窗，若消费方见 `loading`
/// 就画骨架，每次进资料库都会闪一下永远不会有结果的占位。
///
/// 返回能力实例而非 `bool`：`RemotePlaylistCapable` 与 `MusicSource` 无继承
/// 关系，Dart 的类型提升在这里不生效，集中做一次收窄可让调用方免于强转。
final remotePlaylistCapableProvider =
    Provider.family<RemotePlaylistCapable?, String>((ref, sourceId) {
      final account = ref.watch(sourceAccountProvider(sourceId));
      if (account.status != AccountStatus.loggedIn) return null;
      return switch (ref.watch(sourceRegistryProvider).resolve(sourceId)) {
        final RemotePlaylistCapable capable => capable,
        _ => null,
      };
    });

/// 指定账号歌单的曲目列表。
///
/// 与列表页同构：失败保留在 [AsyncValue.error] 里由 UI 渲染「重试」，
/// 渠道未注册 / 不支持能力才降级成空列表（那不是错误）。
final remotePlaylistTracksProvider =
    FutureProvider.family<List<Track>, RemotePlaylist>((ref, playlist) {
      return switch (ref
          .watch(sourceRegistryProvider)
          .resolve(playlist.sourceId)) {
        final RemotePlaylistCapable capable => capable
            .fetchRemotePlaylistTracks(playlist.id),
        _ => Future<List<Track>>.value(const <Track>[]),
      };
    });

/// 失败态展示文案。
///
/// 渠道异常已把「网络异常 / 需要登录」等领域信息放在 [SourceException.message]
/// 里，直接取用；其余未知异常退化为带原文的通用文案——它可能包含 URL，
/// 所以只在非渠道异常时使用（渠道异常禁止把底层细节透给界面）。
String remotePlaylistsErrorMessage(Object error) =>
    error is SourceException ? error.message : '加载失败：$error';
