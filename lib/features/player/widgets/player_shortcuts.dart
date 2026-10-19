import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player_notifier.dart';

/// 全局播放快捷键（桌面端日常使用的基本功）：
///
/// | 按键 | 动作 |
/// |---|---|
/// | 空格 / 键盘媒体键「播放暂停」 | 播放 / 暂停 |
/// | Ctrl(⌘) + → / 媒体键「下一首」 | 下一首 |
/// | Ctrl(⌘) + ← / 媒体键「上一首」 | 上一首 |
/// | Esc | 返回上一页（与 Android 返回键一致，见 [onBack]） |
///
/// **正在输入文字时不拦截**：桌面端按键事件先于文本输入分发，若这里把
/// 空格当成「暂停」处理掉，搜索框就再也打不出空格。因此动作在焦点位于
/// 输入框内时置为不可用，按键原样交还给输入框。
class PlayerShortcuts extends ConsumerWidget {
  const PlayerShortcuts({super.key, required this.child, this.onBack});

  final Widget child;

  /// Esc 的「返回」动作。由组合根传入路由的 `popRoute`：它与系统返回键
  /// 走同一条路径，能正确弹出嵌套导航器里的页面（搜索结果、设置子页）。
  /// 弹窗 / 底部弹层自带 Esc 关闭，处于更深的焦点层级，会先于这里处理。
  final Future<bool> Function()? onBack;

  static final Map<ShortcutActivator, Intent> _shortcuts =
      <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.space):
            const _TogglePlayIntent(),
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause):
            const _TogglePlayIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowRight, control: true):
            const _NextIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowRight, meta: true):
            const _NextIntent(),
        const SingleActivator(LogicalKeyboardKey.mediaTrackNext):
            const _NextIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true):
            const _PreviousIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, meta: true):
            const _PreviousIntent(),
        const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious):
            const _PreviousIntent(),
        const SingleActivator(LogicalKeyboardKey.escape): const _BackIntent(),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    PlayerNotifier notifier() => ref.read(playerNotifierProvider.notifier);
    bool hasQueue() => ref.read(playerNotifierProvider).hasQueue;
    return Shortcuts(
      shortcuts: _shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _TogglePlayIntent: _PlayerAction<_TogglePlayIntent>(
            hasQueue,
            () => notifier().toggle(),
          ),
          _NextIntent: _PlayerAction<_NextIntent>(
            hasQueue,
            () => notifier().next(),
          ),
          _PreviousIntent: _PlayerAction<_PreviousIntent>(
            hasQueue,
            () => notifier().previous(),
          ),
          if (onBack case final back?)
            _BackIntent: _PlayerAction<_BackIntent>(() => true, back),
        },
        child: child,
      ),
    );
  }
}

class _TogglePlayIntent extends Intent {
  const _TogglePlayIntent();
}

class _NextIntent extends Intent {
  const _NextIntent();
}

class _PreviousIntent extends Intent {
  const _PreviousIntent();
}

class _BackIntent extends Intent {
  const _BackIntent();
}

class _PlayerAction<T extends Intent> extends Action<T> {
  _PlayerAction(this._hasQueue, this._run);

  final bool Function() _hasQueue;
  final Future<Object?> Function() _run;

  @override
  bool isEnabled(T intent) => _hasQueue() && !_isTyping();

  @override
  Object? invoke(T intent) => _run();

  /// 焦点是否在文本输入框内。
  static bool _isTyping() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    return focusContext.widget is EditableText ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }
}
