import 'package:meta/meta.dart';

/// 一次「从别处发起的导航请求」（日常可用性计划 D5 / D6）。
///
/// ## 为什么不能直接把参数当 `extra` 传
///
/// go_router 的 `RouterDelegate.setNewRoutePath` 会用
/// `RouteMatchList ==` 做去重，而 `RouteMatchList` 比较的正是 `extra ==`。
/// 于是「值相同」会被判成「路由没有变化」，导航被**静默丢弃**。
/// 这在本计划的两个场景里都会真实发生：
///
/// - 资料库先以「喜欢」进入（extra = 0），用户手动切到「歌单」，
///   回首页再点「喜欢（N）」——extra 仍是 0，页面停在歌单 Tab；
/// - 在某艺人的搜索结果里再点同一个艺人——extra 还是同一个字符串，
///   结果页被 pop 掉却不会重新发起搜索，用户只看到一张空表单。
///
/// 带上自增 [serial] 后，每次点击都是新实例，`==` 必然为 false，
/// 导航必定生效；页面只需比较 `serial` 就能做到「每次请求消费一次」。
@immutable
class NavIntent<T> {
  NavIntent(this.value) : serial = ++_serial;

  /// 全局自增序号（进程内单调递增即可，无需持久化）。
  static int _serial = 0;

  /// 请求携带的值（搜索关键词 / 目标 Tab 索引）。
  final T value;

  /// 自增序号：用于区分「值相同但确实是新的一次点击」。
  final int serial;

  /// 供 go_router 序列化 `extra` 时使用。
  ///
  /// go_router 在向平台上报路由状态时会 `jsonEncode(extra)`；
  /// 没有 `toJson` 的自定义对象会被丢掉并在控制台刷一条警告。
  /// 这里提供的编码只为消除警告——解码回来是 Map，页面侧一律做类型判断，
  /// 拿不到 [NavIntent] 时按「没有请求」处理，不会崩。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'value': value,
    'serial': serial,
  };
}

/// 从 go_router 的 `state.extra` 中取出导航请求。
///
/// 类型不符（例如平台还原路由时 `extra` 被 JSON 解码成 Map）返回 null，
/// 调用方按「没有请求」处理——比抛异常更符合「导航是可选的增强」这一定位。
NavIntent<T>? navIntentOf<T>(Object? extra) =>
    extra is NavIntent<T> ? extra : null;
