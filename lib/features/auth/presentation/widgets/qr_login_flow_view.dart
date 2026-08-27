import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/auth/qr_login_poll.dart';
import '../../../../core/auth/source_account.dart';
import '../../../../core/error/source_exception.dart';
import '../../../../core/source/capabilities.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../application/account_notifier.dart';

/// 单条扫码流水线的通用视图：创建会话 → 渲染二维码 → 完成一次轮询后
/// 再定时器续跑（天然防并发重入）。成功即完成登录并关闭所在路由。
///
/// 一切渠道差异都封装在 [QrLoginFlow] 的 create/poll 闭包里；
/// 本组件只依赖 core 抽象，永不 import `lib/sources/`。
class QrLoginFlowView extends ConsumerStatefulWidget {
  const QrLoginFlowView({
    super.key,
    required this.sourceId,
    required this.flow,
  });

  final String sourceId;
  final QrLoginFlow flow;

  @override
  ConsumerState<QrLoginFlowView> createState() => _QrLoginFlowViewState();
}

class _QrLoginFlowViewState extends ConsumerState<QrLoginFlowView> {
  Timer? _pollTimer;
  QrLoginSession? _session;
  String _status = '正在生成二维码…';
  bool _showRefresh = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _pollTimer?.cancel();
    setState(() {
      _status = '正在生成二维码…';
      _showRefresh = false;
      _session = null;
    });
    try {
      final session = await widget.flow.create();
      if (!mounted) return;
      setState(() {
        _session = session;
        _status = widget.flow.scanHint;
      });
      _scheduleNextPoll();
    } on NetworkSourceException catch (e) {
      if (!mounted) return;
      setState(() {
        _status = e.message;
        _showRefresh = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status = '二维码获取失败，请检查网络';
        _showRefresh = true;
      });
    }
  }

  void _scheduleNextPoll() {
    _pollTimer?.cancel();
    _pollTimer = Timer(widget.flow.interval, _poll);
  }

  Future<void> _poll() async {
    final session = _session;
    if (session == null) return;
    QrLoginPoll poll;
    try {
      poll = await widget.flow.poll(session);
    } on NetworkSourceException catch (e) {
      // 明确失败（如授权被取消 / 解析异常）：停止轮询，给出刷新入口
      if (!mounted) return;
      setState(() {
        _status = e.message;
        _showRefresh = true;
      });
      return;
    } catch (_) {
      if (!mounted) return;
      _scheduleNextPoll(); // 瞬时网络抖动：静默重试
      return;
    }
    if (!mounted) return;
    switch (poll) {
      case QrLoginPollWaiting():
        _scheduleNextPoll();
      case QrLoginPollScanned():
        setState(() => _status = '已扫描，请在手机上确认');
        _scheduleNextPoll();
      case QrLoginPollExpired():
        setState(() {
          _status = '二维码已过期';
          _showRefresh = true;
        });
      case QrLoginPollSuccess(:final credentials, :final nickname):
        await _completeLogin(credentials, nickname);
    }
  }

  Future<void> _completeLogin(
    Map<String, String> credentials,
    String? nickname,
  ) async {
    final display = nickname ?? widget.flow.fallbackNickname;
    await ref.read(accountsProvider.notifier).completeLogin(
          widget.sourceId,
          credentials,
          SourceAccount.markNow(
            sourceId: widget.sourceId,
            status: AccountStatus.loggedIn,
            userId: widget.flow.userIdCredentialKey == null
                ? null
                : credentials[widget.flow.userIdCredentialKey!],
            nickname: display,
          ),
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('欢迎，$display')));
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = _session;
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
              child: SizedBox(
                width: 200,
                height: 200,
                child: session == null
                    ? const Center(
                        child:
                            CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Stack(
                        alignment: Alignment.center,
                        children: [
                          if (session.hasPng)
                            Image.memory(session.png!,
                                width: 200, height: 200)
                          else if (session.contentUrl != null)
                            QrImageView(
                              data: session.contentUrl!,
                              size: 200,
                              backgroundColor: Colors.white,
                            ),
                          if (_showRefresh)
                            Positioned.fill(
                              child: Container(
                                color:
                                    Colors.black.withValues(alpha: 0.75),
                                child: Column(
                                  mainAxisAlignment:
                                      MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      _status,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13),
                                    ),
                                    const SizedBox(height: 8),
                                    FilledButton(
                                      style: FilledButton.styleFrom(
                                          backgroundColor:
                                              AppTokens.accent),
                                      onPressed: _start,
                                      child: const Text('刷新'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _status,
              style: TextStyle(
                fontSize: 14,
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            if (widget.flow.footerHint != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.flow.footerHint!,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
