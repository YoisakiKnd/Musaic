import 'package:flutter/widgets.dart';

import '../../../core/theme/app_tokens.dart';

/// 把内容限制在可读宽度内并水平居中。
///
/// 设置、搜索这类以文字和表单为主的页面，在桌面宽窗口里拉满一整行
/// 会让开关离标题半个屏幕远；手机上宽度本就不足，不受影响。
class ReadableWidth extends StatelessWidget {
  const ReadableWidth({
    super.key,
    required this.child,
    this.maxWidth = AppTokens.readableMaxWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
