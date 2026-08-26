import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/app_providers.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../../sources/ytm/youtube_music_source.dart';
import '../../application/account_notifier.dart';

/// YouTube Music 登录页（WebView）：
/// 内嵌 music.youtube.com，用户完成 Google 登录后点「我已登录」，
/// 提取站点 Cookie（含 httpOnly 的 SID/PSID/APISID 族）作为凭据落安全存储。
class YtmusicLoginPage extends ConsumerStatefulWidget {
  const YtmusicLoginPage({super.key});

  @override
  ConsumerState<YtmusicLoginPage> createState() => _YtmusicLoginPageState();
}

class _YtmusicLoginPageState extends ConsumerState<YtmusicLoginPage> {
  bool _submitting = false;
  String _status = '';

  static const String _startUrl = 'https://music.youtube.com/';

  Future<void> _completeLogin() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _status = '正在提取登录凭据…';
    });
    try {
      final manager = CookieManager.instance();
      final cookies = await manager.getCookies(url: WebUri(_startUrl));
      final credentials = <String, String>{
        for (final c in cookies)
          if (c.value is String && (c.value as String).isNotEmpty)
            c.name: c.value as String,
      };
      final source = ref
          .read(sourceRegistryProvider)
          .resolve(YouTubeMusicSource.id) as YouTubeMusicSource?;
      if (source == null) {
        throw Exception('渠道未注册');
      }
      final account = await source.loginWithCookies(credentials);
      if (!mounted) return;
      await ref.read(accountsProvider.notifier).completeLogin(
            YouTubeMusicSource.id,
            credentials,
            account,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('欢迎，${account.nickname ?? 'YouTube Music 用户'}')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _status = '登录失败：未检测到有效登录态，请确认已完成 Google 登录';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录 YouTube Music'),
        actions: [
          TextButton(
            onPressed: _submitting ? null : _completeLogin,
            child: const Text('我已登录',
                style: TextStyle(
                    color: AppTokens.accent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _status,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_startUrl)),
              initialSettings: InAppWebViewSettings(
                // 桌面 UA：避免 Google 拦截嵌入式 WebView 登录
                userAgent:
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 '
                    'Safari/537.36',
                javaScriptEnabled: true,
                thirdPartyCookiesEnabled: true,
                domStorageEnabled: true,
              ),
              onLoadStop: (_, __) {
                if (mounted) setState(() => _status = '');
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                '在上方页面登录 Google 账号后，点击右上角「我已登录」。'
                '凭据仅保存在本机安全存储。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
