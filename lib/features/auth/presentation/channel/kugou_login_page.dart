import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/app_providers.dart';
import '../../../../core/error/source_exception.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../domain/qr_login_poll.dart';
import '../../domain/source_account.dart';
import '../../application/account_notifier.dart';
import '../../../../sources/kugou/kugou_source.dart';

/// 酷狗音乐登录页：h5 二维码扫码（酷狗 App 扫码 → 确认 → 换取 token）。
class KugouLoginPage extends ConsumerStatefulWidget {
  const KugouLoginPage({super.key});

  @override
  ConsumerState<KugouLoginPage> createState() => _KugouLoginPageState();
}

class _KugouLoginPageState extends ConsumerState<KugouLoginPage> {
  Timer? _pollTimer;
  String? _qrKey;
  Uint8List? _qrPng;
  String _status = '正在生成二维码…';
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _startQrLogin();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _startQrLogin() async {
    _pollTimer?.cancel();
    setState(() {
      _status = '正在生成二维码…';
      _expired = false;
      _qrPng = null;
      _qrKey = null;
    });
    final source =
        ref.read(sourceRegistryProvider).resolve('kugou') as KugouSource?;
    if (source == null) {
      setState(() => _status = '渠道未注册');
      return;
    }
    try {
      final session = await source.createQrLogin();
      if (!mounted) return;
      setState(() {
        _qrPng = session.png;
        _qrKey = session.qrKey;
        _status = '请使用酷狗音乐 App 扫码';
      });
      _pollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _poll(source),
      );
    } on NetworkSourceException catch (e) {
      if (!mounted) return;
      setState(() => _status = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = '二维码获取失败，请检查网络');
    }
  }

  Future<void> _poll(KugouSource source) async {
    if (_qrKey == null) return;
    try {
      final poll = await source.pollQrLogin(_qrKey!);
      if (!mounted) return;
      switch (poll) {
        case QrLoginPollWaiting():
          break;
        case QrLoginPollScanned():
          setState(() => _status = '已扫描，请在手机上确认');
        case QrLoginPollExpired():
          _pollTimer?.cancel();
          setState(() {
            _status = '二维码已过期';
            _expired = true;
          });
        case QrLoginPollSuccess(:final credentials, :final nickname):
          _pollTimer?.cancel();
          await ref.read(accountsProvider.notifier).completeLogin(
                'kugou',
                credentials,
                SourceAccount.markNow(
                  sourceId: 'kugou',
                  status: AccountStatus.loggedIn,
                  userId: credentials['userid'],
                  nickname: nickname ?? '酷狗用户',
                ),
              );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('欢迎，${nickname ?? '酷狗用户'}')),
          );
          Navigator.of(context).pop(true);
      }
    } catch (_) {
      // 轮询瞬时失败静默重试
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('登录酷狗音乐')),
      body: Center(
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
                child: _qrPng == null
                    ? const SizedBox(
                        width: 200,
                        height: 200,
                        child:
                            Center(child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : Stack(
                        alignment: Alignment.center,
                        children: [
                          Image.memory(_qrPng!, width: 200, height: 200),
                          if (_expired)
                            Container(
                              width: 200,
                              height: 200,
                              color: Colors.black.withValues(alpha: 0.75),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Text('二维码已过期',
                                      style: TextStyle(
                                          color: Colors.white, fontSize: 14)),
                                  const SizedBox(height: 8),
                                  FilledButton(
                                    style: FilledButton.styleFrom(
                                        backgroundColor: AppTokens.accent),
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
              Text(_status,
                  style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurface.withValues(alpha: 0.7),
                  )),
              const SizedBox(height: 8),
              Text('扫码登录后可同步会员权益与账号歌单',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.45),
                  )),
            ],
          ),
        ),
      ),
    );
  }
}
