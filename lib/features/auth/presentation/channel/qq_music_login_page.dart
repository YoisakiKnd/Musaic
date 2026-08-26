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
import '../../../../sources/qqmusic/qq_music_source.dart';

/// QQ 音乐登录页：ptlogin 扫码（QQ App 扫码 → 确认 → 自动换取音乐凭据）。
class QqMusicLoginPage extends ConsumerStatefulWidget {
  const QqMusicLoginPage({super.key});

  @override
  ConsumerState<QqMusicLoginPage> createState() => _QqMusicLoginPageState();
}

class _QqMusicLoginPageState extends ConsumerState<QqMusicLoginPage> {
  Timer? _pollTimer;
  String? _qrsig;
  Uint8List? _qrPng;
  String _status = '正在生成二维码…';
  bool _expired = false;
  bool _exchanging = false;

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
      _qrsig = null;
    });
    final source =
        ref.read(sourceRegistryProvider).resolve('qqmusic') as QqMusicSource?;
    if (source == null) {
      setState(() => _status = '渠道未注册');
      return;
    }
    try {
      final session = await source.createQrLogin();
      if (!mounted) return;
      setState(() {
        _qrPng = session.png;
        _qrsig = session.qrsig;
        _status = '请使用 QQ 扫一扫，登录后同步会员权益';
      });
      _pollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _poll(source),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = '二维码获取失败，请检查网络');
    }
  }

  Future<void> _poll(QqMusicSource source) async {
    if (_qrsig == null || _exchanging) return;
    try {
      final poll = await source.pollQrLogin(_qrsig!);
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
          _exchanging = true;
          _pollTimer?.cancel();
          await ref.read(accountsProvider.notifier).completeLogin(
                'qqmusic',
                credentials,
                SourceAccount.markNow(
                  sourceId: 'qqmusic',
                  status: AccountStatus.loggedIn,
                  userId: credentials['uin'],
                  nickname: nickname ?? 'QQ 音乐用户',
                ),
              );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('欢迎，${nickname ?? 'QQ 音乐用户'}')),
          );
          Navigator.of(context).pop(true);
      }
    } on NetworkSourceException catch (e) {
      _exchanging = true;
      _pollTimer?.cancel();
      if (!mounted) return;
      setState(() => _status = e.message);
    } catch (_) {
      // 轮询瞬时失败静默重试
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('登录 QQ 音乐')),
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
              Text('扫码登录后可播放会员曲目并同步账号歌单',
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
