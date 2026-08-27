import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/source/capabilities.dart';
import '../../../core/source/music_source.dart';
import '../../../core/theme/app_tokens.dart';
import 'widgets/password_login_view.dart';
import 'widgets/qr_login_flow_view.dart';

/// 通用渠道登录页：按渠道能力自动组装。
///
/// - [QrLoginCapable] → 每条扫码流水线一个 Tab；
/// - [PasswordLoginCapable] → 追加密码表单 Tab；
/// - 多条流水线时渲染 TabBar，单条且无密码表单时直接铺满。
///
/// 新渠道只要实现 core 能力接口即可复用本页，无需新增任何 UI。
class QrLoginPage extends ConsumerStatefulWidget {
  const QrLoginPage({super.key, required this.sourceId});

  final String sourceId;

  @override
  ConsumerState<QrLoginPage> createState() => _QrLoginPageState();
}

class _QrLoginPageState extends ConsumerState<QrLoginPage>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  MusicSource? get _source =>
      ref.read(sourceRegistryProvider).resolve(widget.sourceId);

  void _syncTabs(List<Widget> panels) {
    final old = _tabController;
    if (old != null && old.length == panels.length) return;
    old?.dispose();
    _tabController = panels.length > 1
        ? TabController(length: panels.length, vsync: this)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    if (source == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('渠道登录')),
        body: const Center(child: Text('渠道未注册')),
      );
    }

    final panels = <(String, Widget)>[];
    if (source is QrLoginCapable) {
      for (final flow in (source as QrLoginCapable).qrLoginFlows) {
        panels.add((
          flow.label,
          QrLoginFlowView(sourceId: widget.sourceId, flow: flow),
        ));
      }
    }
    if (source is PasswordLoginCapable) {
      final capable = source as PasswordLoginCapable;
      panels.add((
        capable.passwordTabLabel,
        PasswordLoginView(sourceId: widget.sourceId, login: capable),
      ));
    }

    if (panels.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text('登录 ${source.displayName}')),
        body: const Center(child: Text('该渠道未提供登录方式')),
      );
    }

    _syncTabs(panels.map((p) => p.$2).toList());
    final controller = _tabController;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text('登录 ${source.displayName}')),
      body: Column(
        children: [
          if (controller != null)
            Material(
              color: Colors.transparent,
              child: TabBar(
                controller: controller,
                labelColor: AppTokens.accent,
                unselectedLabelColor:
                    scheme.onSurface.withValues(alpha: 0.55),
                indicatorColor: AppTokens.accent,
                dividerColor: Colors.transparent,
                tabs: [for (final p in panels) Tab(text: p.$1)],
              ),
            ),
          Expanded(
            child: controller == null
                ? panels.single.$2
                : TabBarView(
                    controller: controller,
                    children: [for (final p in panels) p.$2],
                  ),
          ),
        ],
      ),
    );
  }
}
