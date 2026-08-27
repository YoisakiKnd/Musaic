import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_result.dart';
import '../../../core/di/app_providers.dart';
import '../../../core/source/capabilities.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/account_notifier.dart';

/// 通用 WebView 登录页：内嵌渠道声明的登录地址，用户完成登录后
/// 提取站点 Cookie（含 httpOnly）交给 [WebLoginCapable.loginWithWebCookies]
/// 校验并落安全存储。渠道差异（URL / 校验 / 文案）全部来自能力声明。
class WebLoginPage extends ConsumerStatefulWidget {
  const WebLoginPage({super.key, required this.sourceId});

  final String sourceId;

  @override
  ConsumerState<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginPageState extends ConsumerState<WebLoginPage> {
  bool _submitting = false;
  String _status = '';

  WebLoginCapable? get _login {
    final source =
        ref.read(sourceRegistryProvider).resolve(widget.sourceId);
    return source is WebLoginCapable ? source as WebLoginCapable : null;
  }

  String get _displayName {
    final source =
        ref.read(sourceRegistryProvider).resolve(widget.sourceId);
    return source?.displayName ?? '渠道';
  }

  Future<void> _completeLogin() async {
    final login = _login;
    if (login == null) {
      setState(() => _status = '渠道未注册或不支持网页登录');
      return;
    }
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _status = '正在提取登录凭据…';
    });
    try {
      final url = login.webLoginUrl;
      final manager = CookieManager.instance();
      final cookies = await manager.getCookies(
        url: WebUri(url.toString()),
      );
      final credentialMap = <String, String>{
        for (final c in cookies)
          if (c.value is String && (c.value as String).isNotEmpty)
            c.name: c.value as String,
      };
      final result = await login.loginWithWebCookies(credentialMap);
      if (!mounted) return;
      switch (result) {
        case AuthSuccess(:final account, :final credentials):
          await ref.read(accountsProvider.notifier).completeLogin(
                widget.sourceId,
                credentials,
                account,
              );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    '欢迎，${account.nickname ?? _displayName}')),
          );
          Navigator.of(context).pop(true);
        case AuthFailure(:final message):
          setState(() {
            _submitting = false;
            _status = message;
          });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _status = '登录失败：未检测到有效登录态，请确认已完成登录';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final login = _login;
    final scheme = Theme.of(context).colorScheme;
    if (login == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('网页登录')),
        body: const Center(child: Text('渠道不支持网页登录')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('登录 $_displayName'),
        actions: [
          TextButton(
            onPressed: _submitting ? null : _completeLogin,
            child: Text(login.webLoginActionLabel,
                style: const TextStyle(
                    color: AppTokens.accent,
                    fontWeight: FontWeight.w700)),
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
              initialUrlRequest:
                  URLRequest(url: WebUri(login.webLoginUrl.toString())),
              initialSettings: InAppWebViewSettings(
                // 桌面 UA：避免 Google 等拦截嵌入式 WebView 登录
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
                login.webLoginHint,
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
