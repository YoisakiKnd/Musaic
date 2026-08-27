import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/source/capabilities.dart';
import '../../../core/source/music_source.dart';
import 'login_dialog.dart';
import 'qr_login_page.dart';
import 'web_login_page.dart';

/// 渠道登录统一入口：按能力路由到通用登录页 / WebView 页 / 动态表单弹窗。
///
/// 账号管理页与「登录已过期」全局引导共用本函数，路由决策零渠道硬编码。
Future<void> launchChannelLogin(
  BuildContext context,
  WidgetRef ref,
  MusicSource source,
) {
  if (source is QrLoginCapable || source is PasswordLoginCapable) {
    return Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => QrLoginPage(sourceId: source.sourceId),
      ),
    );
  }
  if (source is WebLoginCapable) {
    return Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => WebLoginPage(sourceId: source.sourceId),
      ),
    );
  }
  if (source.authCapability.requiresLogin) {
    return showLoginDialog(context, source);
  }
  return Future.value();
}
