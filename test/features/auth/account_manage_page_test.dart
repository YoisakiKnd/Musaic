import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/auth/auth_capability.dart';
import 'package:musaic/core/auth/qr_login_poll.dart';
import 'package:musaic/core/auth/source_account.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/lyrics/lyric_bundle.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/capabilities.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/core/theme/app_tokens.dart';
import 'package:musaic/features/auth/application/account_notifier.dart';
import 'package:musaic/features/auth/presentation/channel/account_manage_page.dart';

/// 账号管理页的 **UI 接线测试**（覆盖率补强：该页此前 0.7% 覆盖）。
///
/// ## 为什么值得测
///
/// 这个页面是「渠道能力驱动 UI」的样板：登录入口、状态徽标、刷新/退出
/// 按钮、以及免登录渠道的隐藏，全部由能力接口与账号状态推导，没有任何
/// 渠道 id 硬编码。它的正确性完全取决于这些分支，而分支此前没有测试。
///
/// ## 分层
///
/// 用内存假渠道（不碰 Hive、不联网）：只验证「界面按能力与状态渲染出了
/// 正确的东西」。账号状态用 `AccountNotifier` 子类直接播种，避免依赖
/// 真实凭据仓库与启动校验。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 具备扫码登录能力的渠道（应出现在账号列表里）。
  _QrChannel qrChannel({
    AccountStatus status = AccountStatus.loggedOut,
    String? nickname,
    String? vipLabel,
    String? avatarUrl,
  }) => _QrChannel(
    id: 'qrchan',
    name: '扫码渠道',
    capability: AuthCapability.qr,
    account: SourceAccount(
      sourceId: 'qrchan',
      status: status,
      nickname: nickname,
      vipLabel: vipLabel,
      avatarUrl: avatarUrl,
    ),
  );

  /// 免登录且无账号 UI 的渠道（如本地文件，应被过滤掉）。
  _FakeChannel noAuthChannel() => _FakeChannel(
    id: 'localish',
    name: '免登录渠道',
    capability: AuthCapability.noAuth,
    account: const SourceAccount(
      sourceId: 'localish',
      status: AccountStatus.loggedOut,
    ),
  );

  Future<void> pumpPage(
    WidgetTester tester, {
    required List<_FakeChannel> channels,
    AccountNotifier Function()? accounts,
  }) async {
    final registry = SourceRegistry();
    for (final channel in channels) {
      registry.register(channel);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceRegistryProvider.overrideWithValue(registry),
          accountsProvider.overrideWith(
            accounts ?? () => _SeededAccounts(channels),
          ),
        ],
        child: MaterialApp(
          theme: AppTokens.darkTheme,
          home: const AccountManagePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('未登录渠道：显示「未登录」与进入箭头，可点进登录页', (tester) async {
    await pumpPage(tester, channels: [qrChannel()]);

    expect(find.text('账号管理'), findsOneWidget);
    expect(find.text('扫码渠道'), findsOneWidget);
    expect(find.text('未登录'), findsOneWidget);
    // 未登录时右侧是进入箭头，而非刷新/退出按钮
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(find.byTooltip('刷新资料'), findsNothing);
    expect(find.byTooltip('退出账号'), findsNothing);
  });

  testWidgets('已登录渠道：显示昵称/渠道名/会员标签，并给出刷新与退出按钮', (tester) async {
    await pumpPage(
      tester,
      channels: [
        qrChannel(
          status: AccountStatus.loggedIn,
          nickname: '小明',
          vipLabel: 'VIP',
        ),
      ],
    );

    // 昵称同时出现在标题与状态行（状态行在已登录时显示昵称），故为 2 处
    expect(find.text('小明'), findsNWidgets(2));
    expect(find.text('扫码渠道'), findsOneWidget);
    expect(find.text('VIP'), findsOneWidget);
    // 已登录才有这两个操作
    expect(find.byTooltip('刷新资料'), findsOneWidget);
    expect(find.byTooltip('退出账号'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });

  testWidgets('已登录但无昵称：状态行回退为「已登录」，标题回退为渠道名', (tester) async {
    await pumpPage(
      tester,
      channels: [qrChannel(status: AccountStatus.loggedIn)],
    );

    expect(find.text('已登录'), findsOneWidget);
    // 无昵称时不重复渲染渠道名（标题已是渠道名）
    expect(find.text('扫码渠道'), findsOneWidget);
  });

  testWidgets('过期渠道：显示「已过期，请重新登录」，且不再显示退出按钮', (tester) async {
    await pumpPage(
      tester,
      channels: [qrChannel(status: AccountStatus.expired)],
    );

    expect(find.text('已过期，请重新登录'), findsOneWidget);
    // 过期态不是 isLoggedIn，因此是进入箭头
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(find.byTooltip('退出账号'), findsNothing);
  });

  testWidgets('免登录渠道被过滤掉，不渲染其条目', (tester) async {
    await pumpPage(tester, channels: [qrChannel(), noAuthChannel()]);

    expect(find.text('扫码渠道'), findsOneWidget);
    expect(find.text('免登录渠道'), findsNothing);
  });

  testWidgets('多个渠道各渲染一条，且「一键清除」始终存在', (tester) async {
    await pumpPage(
      tester,
      channels: [
        qrChannel(),
        _FakeChannel(
          id: 'pwchan',
          name: '密码渠道',
          capability: const AuthCapability(type: AuthType.password),
          account: const SourceAccount(
            sourceId: 'pwchan',
            status: AccountStatus.loggedOut,
          ),
        ),
      ],
    );

    expect(find.text('扫码渠道'), findsOneWidget);
    expect(find.text('密码渠道'), findsOneWidget);
    expect(find.text('一键清除所有账号数据'), findsOneWidget);
  });

  testWidgets('一键清除：取消则不清除，确认才调用 clearAllAccountsData', (tester) async {
    final accounts = _RecordingAccounts();
    await pumpPage(tester, channels: [qrChannel()], accounts: () => accounts);

    // ---- 取消：不应触发清除 ----
    await tester.tap(find.text('一键清除所有账号数据'));
    await tester.pumpAndSettle();
    expect(find.text('清除所有账号数据？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(accounts.clearCalls, 0, reason: '取消后不得清除账号数据');

    // ---- 确认：触发清除并给出反馈 ----
    await tester.tap(find.text('一键清除所有账号数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(accounts.clearCalls, 1);
    expect(find.text('账号数据已清除'), findsOneWidget);
  });

  testWidgets('退出账号：取消不退出，确认才调用 logout', (tester) async {
    final accounts = _RecordingAccounts(
      seed: <String, SourceAccount>{
        'qrchan': SourceAccount.markNow(
          sourceId: 'qrchan',
          status: AccountStatus.loggedIn,
          nickname: '小明',
        ),
      },
    );
    await pumpPage(
      tester,
      channels: [qrChannel(status: AccountStatus.loggedIn, nickname: '小明')],
      accounts: () => accounts,
    );

    await tester.tap(find.byTooltip('退出账号'));
    await tester.pumpAndSettle();
    expect(find.text('退出 扫码渠道？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(accounts.logoutCalls, isEmpty, reason: '取消后不得退出');

    await tester.tap(find.byTooltip('退出账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(accounts.logoutCalls, <String>['qrchan']);
  });

  testWidgets('刷新资料：成功后提示「已更新：昵称」，失败则提示可读文案', (tester) async {
    final accounts = _RecordingAccounts(
      seed: <String, SourceAccount>{
        'qrchan': SourceAccount.markNow(
          sourceId: 'qrchan',
          status: AccountStatus.loggedIn,
          nickname: '小明',
        ),
      },
      refreshed: SourceAccount.markNow(
        sourceId: 'qrchan',
        status: AccountStatus.loggedIn,
        nickname: '小红',
        vipLabel: 'VIP',
      ),
    );
    await pumpPage(
      tester,
      channels: [qrChannel(status: AccountStatus.loggedIn, nickname: '小明')],
      accounts: () => accounts,
    );

    await tester.tap(find.byTooltip('刷新资料'));
    await tester.pumpAndSettle();
    expect(find.text('已更新：小红 · VIP'), findsOneWidget);
    expect(accounts.refreshCalls, <String>['qrchan']);
  });

  testWidgets('刷新资料返回 null：提示该渠道不支持刷新（不是静默失败）', (tester) async {
    final accounts = _RecordingAccounts(
      seed: <String, SourceAccount>{
        'qrchan': SourceAccount.markNow(
          sourceId: 'qrchan',
          status: AccountStatus.loggedIn,
          nickname: '小明',
        ),
      },
      refreshed: null,
    );
    await pumpPage(
      tester,
      channels: [qrChannel(status: AccountStatus.loggedIn, nickname: '小明')],
      accounts: () => accounts,
    );

    await tester.tap(find.byTooltip('刷新资料'));
    await tester.pumpAndSettle();
    expect(find.text('该渠道暂不支持刷新资料'), findsOneWidget);
  });

  testWidgets('刷新资料抛异常：给出可读提示而非崩溃', (tester) async {
    final accounts = _RecordingAccounts(
      seed: <String, SourceAccount>{
        'qrchan': SourceAccount.markNow(
          sourceId: 'qrchan',
          status: AccountStatus.loggedIn,
          nickname: '小明',
        ),
      },
      refreshThrows: true,
    );
    await pumpPage(
      tester,
      channels: [qrChannel(status: AccountStatus.loggedIn, nickname: '小明')],
      accounts: () => accounts,
    );

    await tester.tap(find.byTooltip('刷新资料'));
    await tester.pumpAndSettle();
    expect(find.text('刷新失败，请检查网络或重新登录'), findsOneWidget);
  });
}

/// 播种账号状态的 Notifier：直接给出每个渠道的账号，跳过真实凭据读取。
class _SeededAccounts extends AccountNotifier {
  _SeededAccounts(this.channels);

  final List<_FakeChannel> channels;

  @override
  AccountsState build() => AccountsState(
    bySource: <String, SourceAccount>{
      for (final channel in channels) channel.id: channel.account,
    },
  );
}

/// 记录调用的 Notifier，用于断言「取消时什么都没发生」。
class _RecordingAccounts extends AccountNotifier {
  _RecordingAccounts({
    Map<String, SourceAccount>? seed,
    this.refreshed,
    this.refreshThrows = false,
  }) : _seed = seed ?? const <String, SourceAccount>{};

  final Map<String, SourceAccount> _seed;
  final SourceAccount? refreshed;
  final bool refreshThrows;

  int clearCalls = 0;
  final List<String> logoutCalls = <String>[];
  final List<String> refreshCalls = <String>[];

  @override
  AccountsState build() => AccountsState(bySource: _seed);

  @override
  Future<void> clearAllAccountsData() async {
    clearCalls++;
    state = const AccountsState();
  }

  @override
  Future<void> logout(String sourceId) async {
    logoutCalls.add(sourceId);
    state = AccountsState(
      bySource: <String, SourceAccount>{
        sourceId: SourceAccount(
          sourceId: sourceId,
          status: AccountStatus.loggedOut,
        ),
      },
    );
  }

  @override
  Future<SourceAccount?> refreshAccount(String sourceId) async {
    refreshCalls.add(sourceId);
    if (refreshThrows) throw StateError('模拟刷新失败');
    return refreshed;
  }
}

/// 内存假渠道：只声明能力与账号状态，不做任何网络/磁盘访问。
///
/// 注意：本类**刻意不实现任何登录能力接口**——是否出现在账号列表
/// 完全由 [AuthCapability] 决定。需要「有扫码能力」的渠道用 [_QrChannel]。
class _FakeChannel extends MusicSource {
  _FakeChannel({
    required this.id,
    required this.name,
    required this.capability,
    required this.account,
  }) : super(credentialReader: () async => const <String, String>{});

  final String id;
  final String name;
  final AuthCapability capability;
  final SourceAccount account;

  @override
  String get sourceId => id;

  @override
  String get displayName => name;

  @override
  AuthCapability get authCapability => capability;

  @override
  Future<List<Track>> search(
    String query, {
    int limit = 30,
    int offset = 0,
  }) async => const <Track>[];

  @override
  Future<Track> getTrackDetail(Track track) async => track;

  @override
  Future<ResolvedStream> resolveStream(Track track) async =>
      const ResolvedStream(url: '');

  @override
  Future<LyricBundle?> fetchLyrics(Track track) async => null;
}

/// 具备扫码登录能力的渠道（额外实现 [QrLoginCapable]）。
class _QrChannel extends _FakeChannel implements QrLoginCapable {
  _QrChannel({
    required super.id,
    required super.name,
    required super.capability,
    required super.account,
  });

  @override
  List<QrLoginFlow> get qrLoginFlows => <QrLoginFlow>[
    QrLoginFlow(
      id: '$id-qr',
      label: '扫码登录',
      scanHint: '请扫码',
      create: () async => const QrLoginSession(pollKey: 'k'),
      // 用块体而非 `async => const …`：常量表达式在 async 箭头函数中
      // 会报「Not a constant expression」。
      poll: (key) async {
        return const QrLoginPollWaiting();
      },
    ),
  ];
}
