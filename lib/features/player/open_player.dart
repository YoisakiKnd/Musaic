import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_tokens.dart';

/// 点歌开始播放后，是否顺带打开全屏播放页。
///
/// 手机上没有别处能看到播放状态，进入播放页；平板 / 桌面底部常驻完整
/// 播放条，留在当前列表继续挑歌——每点一首都整屏切走在桌面上很打断。
Future<void> openPlayerAfterPlay(BuildContext context) async {
  if (MediaQuery.sizeOf(context).width >= AppTokens.mediumBreakpoint) return;
  await context.push('/player');
}
