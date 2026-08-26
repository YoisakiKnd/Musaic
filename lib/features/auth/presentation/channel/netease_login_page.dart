import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../core/di/app_providers.dart';
import '../../domain/auth_result.dart';
import '../../domain/qr_login_poll.dart';
import '../../domain/source_account.dart';
import '../../application/account_notifier.dart';
import '../../../../sources/netease/netease_source.dart';

/// 网易云音乐登录页（渠道独立适配）：
/// - 二维码登录：网易云 App 扫码，轮询 unikey 状态
/// - 手机号 + 密码：weapi 加密真实请求
class NeteaseLoginPage extends ConsumerStatefulWidget {
  const NeteaseLoginPage({super.key});

  @override
  ConsumerState<NeteaseLoginPage> createState() => _NeteaseLoginPageState();
}

class _NeteaseLoginPageState extends ConsumerState<NeteaseLoginPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  Timer? _pollTimer;
  String? _qrKey;
  String _qrStatus = '正在生成二维码…';
  bool _qrExpired = false;

  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  String? _phoneError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _startQrLogin();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tabController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _startQrLogin() async {
    setState(() {
      _qrStatus = '正在生成二维码…';
      _qrExpired = false;
    });
    final source =
        ref.read(sourceRegistryProvider).resolve('netease')
            as NeteaseSource?;
    if (source == null) {
      setState(() => _qrStatus = '渠道未注册');
      return;
    }
    try {
      final session = await source.createQrLogin();
      _qrKey = session.key;
      setState(() => _qrStatus = '请使用网易云音乐 App 扫码');
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _poll(source),
      );
    } catch (e) {
      // 真机联调定位用；错误详情进调试输出，UI 只提示网络问题
      debugPrint('MusaicNeteaseQR createQrLogin 失败: $e');
      if (!mounted) return;
      setState(() => _qrStatus = '二维码获取失败，请检查网络');
    }
  }

  Future<void> _poll(NeteaseSource source) async {
    if (_qrKey == null) return;
    try {
      final poll = await source.pollQrLogin(_qrKey!);
      switch (poll) {
        case QrLoginPollWaiting():
          break;
        case QrLoginPollScanned():
          setState(() => _qrStatus = '已扫描，请在手机上确认');
        case QrLoginPollExpired():
          _pollTimer?.cancel();
          setState(() {
            _qrStatus = '二维码已过期';
            _qrExpired = true;
          });
        case QrLoginPollSuccess(:final credentials, :final nickname):
          _pollTimer?.cancel();
          await ref.read(accountsProvider.notifier).completeLogin(
                'netease',
                credentials,
                SourceAccount.markNow(
                  sourceId: 'netease',
                  status: AccountStatus.loggedIn,
                  nickname: nickname,
                ),
              );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('欢迎，${nickname ?? '网易云用户'}')),
          );
          Navigator.of(context).pop(true);
      }
    } catch (_) {
      // 轮询失败静默重试
    }
  }

  Future<void> _loginByPhone() async {
    final phone = _phoneController.text.trim();
    final password = _passwordController.text;
    if (phone.isEmpty || password.isEmpty) {
      setState(() => _phoneError = '请输入手机号和密码');
      return;
    }
    setState(() {
      _submitting = true;
      _phoneError = null;
    });
    final source =
        ref.read(sourceRegistryProvider).resolve('netease')
            as NeteaseSource?;
    if (source == null) {
      setState(() {
        _submitting = false;
        _phoneError = '渠道未注册';
      });
      return;
    }
    final result = await source.loginByPhone(phone, password);
    if (!mounted) return;
    setState(() => _submitting = false);
    switch (result) {
      case AuthSuccess(:final account, :final credentials):
        await ref.read(accountsProvider.notifier).completeLogin(
              'netease',
              credentials,
              account,
            );
        if (!mounted) return;
        Navigator.of(context).pop(true);
      case AuthFailure(:final message):
        setState(() => _phoneError = message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('登录网易云音乐')),
      body: Column(
        children: [
          Material(
            color: Colors.transparent,
            child: TabBar(
              controller: _tabController,
              labelColor: AppTokens.accent,
              unselectedLabelColor:
                  scheme.onSurface.withValues(alpha: 0.55),
              indicatorColor: AppTokens.accent,
              dividerColor: Colors.transparent,
              tabs: const [
                Tab(text: '二维码登录'),
                Tab(text: '手机号登录'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildQrTab(context),
                _buildPhoneTab(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQrTab(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: _qrKey == null
                  ? const SizedBox(
                      width: 200,
                      height: 200,
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Stack(
                      alignment: Alignment.center,
                      children: [
                        QrImageView(
                          data: _qrKey == null
                              ? ''
                              : 'https://music.163.com/login?codekey=$_qrKey',
                          size: 200,
                          backgroundColor: Colors.white,
                        ),
                        if (_qrExpired)
                          Container(
                            width: 200,
                            height: 200,
                            color: Colors.black.withValues(alpha: 0.75),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Text('二维码已过期',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 14)),
                                const SizedBox(height: 8),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                      backgroundColor:
                                          AppTokens.accent),
                                  onPressed: _startQrLogin,
                                  child: const Text('刷新'),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 20),
            Text(_qrStatus,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7),
                )),
            const SizedBox(height: 8),
            Text('扫码登录后可播放 VIP 曲目并同步账号歌单',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.45),
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildPhoneTab(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: '手机号',
              prefixText: '+86 ',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: '密码',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          if (_phoneError != null) ...[
            const SizedBox(height: 12),
            Text(_phoneError!,
                style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTokens.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            onPressed: _submitting ? null : _loginByPhone,
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('登录'),
          ),
          const SizedBox(height: 12),
          Text(
            '密码经 weapi 标准加密后提交，本机不保存明文',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }
}
