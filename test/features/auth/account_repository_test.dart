import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:musaic/features/auth/domain/source_account.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/features/auth/data/account_repository.dart';

/// 内存版凭据存储替身（替代 flutter_secure_storage 平台通道）。
class _InMemorySecureStore implements SecureCredentialStore {
  final Map<String, String> store = <String, String>{};

  @override
  Future<Map<String, String>> readAll() async => Map.of(store);

  @override
  Future<void> write(String key, String value) async => store[key] = value;

  @override
  Future<void> delete(String key) async => store.remove(key);
}

Track _track(String id) => Track(
      id: id,
      sourceId: 'netease',
      title: 't$id',
      artist: 'a',
    );

void main() {
  late Directory tempDir;
  late Box<String> box;
  late _InMemorySecureStore secure;
  late AccountRepository repository;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_hive_test');
    Hive.init(tempDir.path);
    box = await Hive.openBox<String>('musaic_accounts_test_box');
  });

  tearDownAll(() async {
    await box.close();
    await tempDir.delete(recursive: true);
  });

  setUp(() async {
    await box.clear();
    secure = _InMemorySecureStore();
    repository = AccountRepository(
      credentialStore: secure,
      accountBox: box,
    );
  });

  group('凭据命名空间隔离（存储层单元测试要求）', () {
    test('不同渠道凭据互不可见', () async {
      await repository.saveCredentials(
          'netease', {'MUSIC_U': 'abc'});
      await repository.saveCredentials('qqmusic', {'TOKEN': 'xyz'});

      final netease = await repository.readCredentials('netease');
      final qq = await repository.readCredentials('qqmusic');

      expect(netease.keys, ['MUSIC_U']);
      expect(qq.keys, ['TOKEN']);
      expect(netease.containsKey('TOKEN'), isFalse);
    });

    test('同渠道整体覆盖保存', () async {
      await repository.saveCredentials(
          'netease', {'MUSIC_U': 'old', 'EXTRA': 'e'});
      await repository.saveCredentials('netease', {'MUSIC_U': 'new'});

      final creds = await repository.readCredentials('netease');
      expect(creds, {'MUSIC_U': 'new'});
    });

    test('输入清洗：去首尾空白与内部换行/制表符', () async {
      await repository.saveCredentials('netease', {
        'MUSIC_U': '  abc\ndef\tghi\n',
      });
      final creds = await repository.readCredentials('netease');
      expect(creds['MUSIC_U'], 'abcdefghi');
    });
  });

  test('账号状态保存与启动恢复', () async {
    final account = SourceAccount.markNow(
      sourceId: 'netease',
      status: AccountStatus.loggedIn,
      nickname: '云村民',
    );
    await repository.saveAccount(account);

    final restored = repository.restoreAll();
    expect(restored['netease']?.status, AccountStatus.loggedIn);
    expect(restored['netease']?.nickname, '云村民');
  });

  test('损坏的状态记录降级为 loggedOut 而非抛异常', () async {
    await box.put('netease', '{broken json');
    final account = repository.readAccount('netease');
    expect(account.status, AccountStatus.loggedOut);
  });

  test('markExpired 仅作用于 loggedIn，过期不删凭据', () async {
    await repository.saveCredentials('netease', {'MUSIC_U': 'keep-me'});

    // loggedOut → 不变
    await repository.markExpired('netease');
    expect(repository.readAccount('netease').status,
        AccountStatus.loggedOut);

    // loggedIn → expired，凭据保留
    await repository.saveAccount(SourceAccount.markNow(
      sourceId: 'netease',
      status: AccountStatus.loggedIn,
      nickname: 'n',
    ));
    await repository.markExpired('netease');

    expect(repository.readAccount('netease').isExpired, isTrue);
    final creds = await repository.readCredentials('netease');
    expect(creds['MUSIC_U'], 'keep-me');
  });

  test('logout 删除凭据并重置状态', () async {
    await repository.saveCredentials('netease', {'MUSIC_U': 'x'});
    await repository.saveAccount(SourceAccount.markNow(
      sourceId: 'netease',
      status: AccountStatus.loggedIn,
    ));

    await repository.logout('netease');

    expect(await repository.readCredentials('netease'), isEmpty);
    expect(repository.readAccount('netease').status,
        AccountStatus.loggedOut);
  });

  test('clearAll 一键清除凭据与全部账号资料', () async {
    await repository.saveCredentials('netease', {'MUSIC_U': 'a'});
    await repository.saveCredentials('local', {'PATH_KEY': 'b'});
    await repository.saveAccount(SourceAccount.markNow(
      sourceId: 'netease',
      status: AccountStatus.loggedIn,
    ));

    await repository.clearAll();

    expect(
      secure.store.keys
          .where((k) => k.startsWith('musaic.credential')),
      isEmpty,
    );
    expect(repository.restoreAll(), isEmpty);
  });

  test('历史记录裁剪上限（LibraryRepository 与仓库无关，此处仅冒烟 Track 序列化）', () {
    final json = _track('1').toJson();
    expect(Track.fromJson(json).key, 'netease:1');
  });
}
