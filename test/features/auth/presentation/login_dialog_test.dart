import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/core/source/music_source.dart';
import 'package:musaic/core/di/app_providers.dart';
import 'package:musaic/core/source/source_registry.dart';
import 'package:musaic/features/auth/application/account_notifier.dart';
import 'package:musaic/features/lyrics/domain/lyric_bundle.dart';
import 'package:musaic/features/auth/domain/auth_capability.dart';
import 'package:musaic/features/auth/domain/auth_result.dart';
import 'package:musaic/features/auth/domain/source_account.dart';
import 'package:musaic/features/auth/presentation/login_dialog.dart';

class _FakeNetease extends MusicSource {
  _FakeNetease() : super(credentialReader: () async => {});

  @override
  String get sourceId => 'netease';

  @override
  String get displayName => '网易云音乐';

  @override
  AuthCapability get authCapability => const AuthCapability(
        type: AuthType.cookie,
        fields: [
          CredentialField(
            key: 'MUSIC_U',
            label: 'MUSIC_U',
            placeholder: '粘贴 MUSIC_U 的纯值',
          ),
        ],
        guide: AuthGuide(title: '如何获取 MUSIC_U', steps: ['步骤一', '步骤二']),
      );

  @override
  Future<AuthResult> login(Map<String, String> credentials) async {
    if ((credentials['MUSIC_U'] ?? '').trim() == 'good-cookie') {
      return AuthSuccess(SourceAccount.markNow(
        sourceId: sourceId,
        status: AccountStatus.loggedIn,
        nickname: '测试用户',
      ));
    }
    return const AuthFailure(
      reason: AuthFailureReason.invalidCredentials,
      message: 'Cookie 无效或已过期，请重新获取',
    );
  }

  @override
  Future<List<Track>> search(String query,
      {int limit = 30, int offset = 0}) async =>
      [];
  @override
  Future<Track> getTrackDetail(Track track) => throw UnimplementedError();
  @override
  Future<ResolvedStream> resolveStream(Track track) =>
      throw UnimplementedError();
  @override
  Future<LyricBundle?> fetchLyrics(Track track) async => null;
}

/// 跳过 Hive/安全存储初始化的账号状态（登录仅走渠道验证，不落盘）。
class _StubAccountsNotifier extends AccountNotifier {
  @override
  AccountsState build() => const AccountsState();

  @override
  Future<AuthResult> login(
    String sourceId,
    Map<String, String> credentials,
  ) async {
    final source = ref.read(sourceRegistryProvider).resolve(sourceId);
    if (source == null) {
      return const AuthFailure(
        reason: AuthFailureReason.unsupported,
        message: '渠道未注册',
      );
    }
    return source.login(credentials);
  }
}

Future<void> _pumpHost(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sourceRegistryProvider.overrideWith((ref) {
          final registry = SourceRegistry()..register(_FakeNetease());
          return registry;
        }),
        accountsProvider.overrideWith(_StubAccountsNotifier.new),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showLoginDialog(context, _FakeNetease()),
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('OPEN'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('动态表单按渠道声明渲染字段与指引',
      (tester) async {
    await _pumpHost(tester);

    expect(find.text('登录网易云音乐'), findsOneWidget);
    expect(find.text('MUSIC_U'), findsWidgets);
    expect(find.text('如何获取 MUSIC_U'), findsOneWidget);
    expect(find.text('步骤一'), findsNothing); // 折叠状态不展示步骤
  });

  testWidgets('无效 Cookie 提交失败并显示原因，弹窗保持打开',
      (tester) async {
    await _pumpHost(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'MUSIC_U'),
      'bad-cookie',
    );
    await tester.tap(find.text('登录'));
    await tester.pump(); // 提交中
    await tester.pump(const Duration(seconds: 1)); // SnackBar 出现

    expect(find.text('Cookie 无效或已过期，请重新获取'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget); // 弹窗未关闭
  });

  testWidgets('有效 Cookie 登录成功后弹窗关闭', (tester) async {
    await _pumpHost(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'MUSIC_U'),
      'good-cookie',
    );
    await tester.tap(find.text('登录'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('欢迎，测试用户'), findsOneWidget);
  });
}
