import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_result.dart';
import '../../../core/di/app_providers.dart';
import '../../../core/source/capabilities.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/account_notifier.dart';
import '../../../core/auth/web_cookie_harvest.dart';
import 'webview_user_agent.dart';

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
  InAppWebViewController? _controller;
  Completer<void>? _loadGate;
  bool _submitting = false;
  String _status = '';

  WebLoginCapable? get _login {
    final source = ref.read(sourceRegistryProvider).resolve(widget.sourceId);
    return source is WebLoginCapable ? source as WebLoginCapable : null;
  }

  String get _displayName {
    final source = ref.read(sourceRegistryProvider).resolve(widget.sourceId);
    return source?.displayName ?? '渠道';
  }

  Future<void> _waitForLoad() async {
    _loadGate = Completer<void>();
    await _loadGate!.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () {},
    );
    _loadGate = null;
  }

  Future<Map<String, String>> _harvestCookies(WebLoginCapable login) async {
    final controller = _controller;
    final manager = CookieManager.instance();
    final collected = <String, String>{};
    final origins = login.webLoginCookieOrigins;
    final urls = <Uri>[];

    void enqueue(Uri uri) {
      if (isCookieHostAllowed(uri.host, origins)) urls.add(uri);
    }

    final current = await controller?.getUrl();
    if (current != null) {
      final currentUri = Uri.tryParse(current.toString());
      if (currentUri != null) enqueue(currentUri);
    }
    for (final origin in origins) {
      enqueue(origin);
    }

    final seen = <String>{};
    for (final origin in urls) {
      if (!seen.add('${origin.scheme}://${origin.host}')) continue;
      final cookies = await manager.getCookies(
        url: WebUri(origin.toString()),
        webViewController: controller,
      );
      for (final cookie in cookies) {
        mergeCookiePair(collected, cookie.name, cookie.value);
      }
    }

    if (controller != null &&
        isCookieHostAllowed(
          Uri.tryParse((await controller.getUrl())?.toString() ?? '')?.host ??
              '',
          origins,
        )) {
      try {
        final js = await controller.evaluateJavascript(
          source: 'document.cookie',
        );
        if (js is String) {
          mergeCookieHeader(collected, js);
        } else if (js != null) {
          mergeCookieHeader(collected, js.toString());
        }
      } catch (_) {}
    }
    return collected;
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
      final controller = _controller;
      final current = (await controller?.getUrl())?.toString() ?? '';
      final host = Uri.tryParse(current)?.host ?? '';
      if (login.webLoginUrl.host.contains('music.youtube.com') &&
          !isCookieHostAllowed(host, login.webLoginCookieOrigins)) {
        setState(() => _status = '正在回到 YouTube Music…');
        await controller?.loadUrl(
          urlRequest: URLRequest(url: WebUri(login.webLoginUrl.toString())),
        );
        await _waitForLoad();
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }

      var cookies = await _harvestCookies(login);
      var attempt = 0;
      while (!hasYoutubeLoginCookies(cookies) &&
          controller != null &&
          attempt < 3) {
        await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        cookies = await _harvestCookies(login);
        attempt += 1;
      }

      if (cookies.isEmpty) {
        throw StateError('empty');
      }
      final result = await login.loginWithWebCookies(cookies);
      if (!mounted) return;
      switch (result) {
        case AuthSuccess(:final account, :final credentials):
          await ref
              .read(accountsProvider.notifier)
              .completeLogin(widget.sourceId, credentials, account);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('欢迎，${account.nickname ?? _displayName}')),
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
        _status = '未能读取登录 Cookie。请确认已登录并回到 YouTube Music 页面后，再点「我已登录」。';
      });
    }
  }

  Future<void> _prepareAndLoad(
    InAppWebViewController controller,
    WebLoginCapable login,
  ) async {
    _controller = controller;
    try {
      final raw = await InAppWebViewController.getDefaultUserAgent();
      final ua = chromeLikeUserAgent(raw);
      if (ua.isNotEmpty) {
        await controller.setSettings(
          settings: InAppWebViewSettings(userAgent: ua),
        );
      }
    } catch (_) {}
    await controller.loadUrl(
      urlRequest: URLRequest(url: WebUri(login.webLoginUrl.toString())),
    );
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
            child: Text(
              login.webLoginActionLabel,
              style: const TextStyle(
                color: AppTokens.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
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
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                javaScriptCanOpenWindowsAutomatically: true,
                supportMultipleWindows: true,
                thirdPartyCookiesEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                cacheEnabled: true,
                sharedCookiesEnabled: true,
                useHybridComposition: true,
              ),
              onWebViewCreated: (controller) {
                _prepareAndLoad(controller, login);
              },
              onCreateWindow: (controller, action) async {
                if (!mounted) return false;
                await showDialog<void>(
                  context: context,
                  builder: (dialogContext) {
                    return Scaffold(
                      appBar: AppBar(
                        title: const Text('登录'),
                        leading: IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(dialogContext).pop(),
                        ),
                      ),
                      body: InAppWebView(
                        windowId: action.windowId,
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          thirdPartyCookiesEnabled: true,
                          domStorageEnabled: true,
                          sharedCookiesEnabled: true,
                        ),
                        onCloseWindow: (_) {
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                        },
                      ),
                    );
                  },
                );
                return true;
              },
              onLoadStop: (_, __) {
                if (_loadGate != null && !_loadGate!.isCompleted) {
                  _loadGate!.complete();
                }
                if (mounted && !_submitting) {
                  setState(() => _status = '');
                }
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
