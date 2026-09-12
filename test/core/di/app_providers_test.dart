import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/source/capabilities.dart';
import 'package:musaic/core/utils/track_link_parser.dart';
import 'package:musaic/features/auth/application/account_notifier.dart';
import 'package:musaic/features/auth/data/account_repository.dart';
import 'package:musaic/features/library/data/library_repository.dart';
import 'package:musaic/features/settings/data/local_music_settings_repository.dart';

/// 组合根装配（T2 覆盖率补强：`app_providers.dart` 此前 10%）。
///
/// 组合根是全应用唯一「跨层装配具体实现」的地方（架构守护测试对它豁免），
/// 也正因如此，写错一处就会让整个应用起不来，而单元测试通常覆盖不到。
///
/// 这里验证两件事：
/// 1. **未 override 时必须显式失败**——这是刻意的设计：静默给出 null
///    会让错误在很远的地方才暴露；
/// 2. **override 后能正确装配出全部渠道**，且注册顺序稳定。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box<String> accountsBox;
  late Box<String> favoritesBox;
  late Box<String> historyBox;
  late Box<String> playlistsBox;
  late Box<String> localMusicBox;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_di_test');
    Hive.init(tempDir.path);
    accountsBox = await Hive.openBox<String>('di_accounts');
    favoritesBox = await Hive.openBox<String>('di_fav');
    historyBox = await Hive.openBox<String>('di_hist');
    playlistsBox = await Hive.openBox<String>('di_pl');
    localMusicBox = await Hive.openBox<String>('di_local');
  });

  tearDownAll(() async {
    for (final box in <Box<String>>[
      accountsBox,
      favoritesBox,
      historyBox,
      playlistsBox,
      localMusicBox,
    ]) {
      if (box.isOpen) await box.close();
    }
    await Hive.close();
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  group('未 override 时显式失败（刻意的设计）', () {
    test('accountRepositoryProvider 抛出可读错误而非返回 null', () {
      final container = ProviderContainer();
      expect(
        () => container.read(accountRepositoryProvider),
        throwsA(isA<StateError>()),
      );
      container.dispose();
    });

    test('libraryRepositoryProvider 同样显式失败', () {
      final container = ProviderContainer();
      expect(
        () => container.read(libraryRepositoryProvider),
        throwsA(isA<StateError>()),
      );
      container.dispose();
    });

    test('错误信息指出「必须在启动时 override」，便于定位', () {
      final container = ProviderContainer();
      try {
        container.read(libraryRepositoryProvider);
        fail('应当抛出');
      } on StateError catch (e) {
        expect(e.message, contains('override'));
      }
      container.dispose();
    });
  });

  group('链接解析器的渠道 id 必须真实存在（回归）', () {
    /// 曾经的真实缺陷：`track_link_parser.dart` 用 `'ytm'` 作为 YouTube
    /// 渠道 id，而实际注册的是 `'ytmusic'`。结果是——粘一条 YouTube 分享
    /// 链接能解析成功，但随后找不到渠道，功能静默失效。
    ///
    /// 这类「字面量拼写与真实 id 不一致」的 bug 靠单测各自的断言发现不了
    /// （解析器测自己的字符串、注册表测自己的 id，两边都「通过」）。
    /// 只有把两者放在一起比对才能拦住。
    test('解析器产出的每个 sourceId 都能在注册表中解析到', () {
      final container = ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(
            AccountRepository(
              credentialStore: _NoopCredentialStore(),
              accountBox: accountsBox,
            ),
          ),
          libraryRepositoryProvider.overrideWithValue(
            LibraryRepository(
              favoritesBox: favoritesBox,
              historyBox: historyBox,
              playlistsBox: playlistsBox,
            ),
          ),
          localMusicSettingsRepositoryProvider.overrideWithValue(
            LocalMusicSettingsRepository(box: localMusicBox),
          ),
          accountsProvider.overrideWith(_EmptyAccounts.new),
        ],
      );
      final registry = container.read(sourceRegistryProvider);

      // 覆盖四个在线渠道 + 本地，逐一确认解析结果能被注册表解析
      const inputs = <String, String>{
        'https://music.163.com/song?id=347230': 'netease',
        'https://y.qq.com/n/ryqq/songDetail/0039MnYb0qxYhV': 'qqmusic',
        'https://www.kugou.com/song/#hash=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6':
            'kugou',
        'https://music.youtube.com/watch?v=dQw4w9WgXcQ': 'ytmusic',
      };

      for (final entry in inputs.entries) {
        final link = parseTrackLink(entry.key);
        expect(link, isNotNull, reason: '应能解析：${entry.key}');
        expect(
          link!.sourceId,
          entry.value,
          reason: '解析出的渠道 id 与预期不符：${entry.key}',
        );
        expect(
          registry.resolve(link.sourceId),
          isNotNull,
          reason:
              '解析出 sourceId="${link.sourceId}"，但注册表中没有该渠道——'
              '用户会看到「渠道不可用」',
        );
      }

      container.dispose();
    });

    test('YouTube 渠道 id 常量为 ytmusic（与渠道实现一致）', () {
      expect(youtubeMusicSourceId, 'ytmusic');
    });
  });

  group('装配后注册全部渠道', () {
    ProviderContainer buildContainer() {
      final accounts = AccountRepository(
        credentialStore: _NoopCredentialStore(),
        accountBox: accountsBox,
      );
      return ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(accounts),
          libraryRepositoryProvider.overrideWithValue(
            LibraryRepository(
              favoritesBox: favoritesBox,
              historyBox: historyBox,
              playlistsBox: playlistsBox,
            ),
          ),
          localMusicSettingsRepositoryProvider.overrideWithValue(
            LocalMusicSettingsRepository(box: localMusicBox),
          ),
          // 账号状态：渠道注册会读它做会话过期回调接线
          accountsProvider.overrideWith(_EmptyAccounts.new),
        ],
      );
    }

    test('注册了全部四个在线渠道 + 本地渠道', () {
      final container = buildContainer();
      final registry = container.read(sourceRegistryProvider);

      expect(registry.contains('netease'), isTrue);
      expect(registry.contains('qqmusic'), isTrue);
      expect(registry.contains('kugou'), isTrue);
      expect(registry.contains('ytmusic'), isTrue);
      expect(registry.contains('local'), isTrue);
      expect(registry.length, 5);

      container.dispose();
    });

    test('渠道 id 与实现类声明的静态 id 一致（改名不会静默失配）', () {
      final container = buildContainer();
      final registry = container.read(sourceRegistryProvider);

      for (final source in registry.all) {
        expect(
          registry.resolve(source.sourceId),
          same(source),
          reason: '${source.displayName} 的 sourceId 无法解析回自身',
        );
      }
      container.dispose();
    });

    test('本地渠道具备扫描能力（设置页依赖它）', () {
      final container = buildContainer();
      final registry = container.read(sourceRegistryProvider);

      final local = registry.resolve('local');
      expect(local, isA<LibraryScanCapable>());
      container.dispose();
    });

    test('在线渠道具备扫码或 Web 登录能力（账号中心依赖它）', () {
      final container = buildContainer();
      final registry = container.read(sourceRegistryProvider);

      // 网易云 / QQ / 酷狗走扫码；YTM 走 WebView
      expect(registry.resolve('netease'), isA<QrLoginCapable>());
      expect(registry.resolve('qqmusic'), isA<QrLoginCapable>());
      expect(registry.resolve('kugou'), isA<QrLoginCapable>());
      expect(registry.resolve('ytmusic'), isA<WebLoginCapable>());
      container.dispose();
    });

    test('网易云具备账号歌单能力', () {
      final container = buildContainer();
      final registry = container.read(sourceRegistryProvider);
      expect(registry.resolve('netease'), isA<RemotePlaylistCapable>());
      container.dispose();
    });

    test('注册顺序稳定（UI 展示顺序依赖它）', () {
      final a = buildContainer()
          .read(sourceRegistryProvider)
          .all
          .map((s) => s.sourceId);
      final b = buildContainer()
          .read(sourceRegistryProvider)
          .all
          .map((s) => s.sourceId);

      expect(a.toList(), b.toList(), reason: '两次装配顺序必须一致，否则渠道列表会随机跳动');
    });

    test('渠道展示名非空（UI 到处依赖它）', () {
      final container = buildContainer();
      for (final source in container.read(sourceRegistryProvider).all) {
        expect(source.displayName.trim(), isNotEmpty);
      }
      container.dispose();
    });
  });
}

/// 空账号状态：避免注册渠道时触碰真实 Hive 校验流程。
class _EmptyAccounts extends AccountNotifier {
  @override
  AccountsState build() => const AccountsState();
}

/// 不落盘的凭据存储：组合根测试不关心真实凭据读写，
/// 也不该触碰系统钥匙串。
class _NoopCredentialStore implements SecureCredentialStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<Map<String, String>> readAll() async => const <String, String>{};

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}
