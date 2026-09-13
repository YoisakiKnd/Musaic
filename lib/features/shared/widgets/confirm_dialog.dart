import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';

/// 破坏性操作的二次确认（用户层交互计划 2.1）。
///
/// ## 为什么需要统一入口
///
/// 项目内原本只有两处破坏性操作带确认（资料库「清空」与账号「清除所有
/// 账号数据」），其余多处（设置页四个清除项、搜索历史清空、移除扫描
/// 文件夹、清空播放队列）都是**点下去立即执行**，只在事后弹一条提示。
/// 这类操作不可恢复，误触后用户没有任何挽回余地。
///
/// 因此把确认对话框收敛到一个函数：调用方只声明「标题 / 说明 / 按钮
/// 文案」，样式与按钮语义（取消在左、破坏性动作在右且用强调色）在
/// 一处保证一致，避免各页各写一份 AlertDialog 而再次漂移。
///
/// 用法（**必须**在 await 后重新判断 `context.mounted`）：
///
/// ```dart
/// final confirmed = await confirmDestructiveAction(
///   context,
///   title: '清除播放历史？',
///   message: '将删除「最近播放」的全部记录，该操作不可恢复。',
/// );
/// if (!confirmed || !context.mounted) return;
/// await repo.clearHistory();
/// ```
///
/// 返回 `true` 仅当用户明确点击了确认按钮；点击遮罩、返回键或取消
/// 一律为 `false`，调用方据此**不做任何写入**。
Future<bool> confirmDestructiveAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '清空',
  String cancelLabel = '取消',
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder:
        (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(cancelLabel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTokens.accent),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        ),
  );
  return confirmed == true;
}
