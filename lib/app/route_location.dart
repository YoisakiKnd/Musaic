import 'package:go_router/go_router.dart';

/// 全屏播放页路径。
///
/// 单独成常量供路由表与「当前是否在播放页」判断共用，避免两处字面量漂移
/// （`router.dart` 的 `path:` 与判断逻辑必须始终指向同一个位置）。
const String playerRoutePath = '/player';

/// 当前是否停留在全屏播放页（[playerRoutePath]）。
///
/// ## 为什么不能用 `router.state.uri` 判断
///
/// 播放页**只**通过 `push` 打开（首页 / 资料库 / 搜索 / 迷你条 / 歌单详情 /
/// 远程歌单等 7 处调用点）。而 go_router 14.8.1 的 `RouteMatchList.uri`
/// 明确只反映**非** `ImperativeRouteMatch` 的匹配——被 push 的 `/player`
/// 不会出现在 `.uri` 里，用它判断会永远得到「不在播放页」，避让逻辑失效。
///
/// 因此改读 `matches.last.matchedLocation`：`ImperativeRouteMatch` 的
/// `matchedLocation` 由其内部 matches 的末项推导，正是被 push 的位置。
///
/// ## 用途
///
/// 全局播放失败提示需要**避让**播放页：播放页自身已有错误横幅
/// （可重试 / 可关闭），不避让会让同一次失败被提示两遍。
///
/// 放在本文件而非 `router.dart`：`router.dart` 已 import `app_shell.dart`，
/// 若把判断函数放进 `router.dart`，`app_shell.dart` 反向 import 会形成
/// 循环依赖。本文件只依赖 go_router，可被两边安全引用。
bool isOnPlayerRoute(GoRouter router) {
  final matches = router.routerDelegate.currentConfiguration.matches;
  if (matches.isEmpty) return false;
  return matches.last.matchedLocation == playerRoutePath;
}
