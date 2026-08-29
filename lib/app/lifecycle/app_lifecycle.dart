import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 应用前后台状态源（功耗计划 PW-03）。
///
/// 由 [AppLifecycleObserver] 桥接 WidgetsBinding 事件：
/// 进入 hidden/paused/detached（息屏、切后台、桌面最小化）后，
/// 所有纯 UI 刷新（进度条、歌词高亮、倒计时）应当跳过或降频；
/// 音频播放与断点快照不受影响。
final appLifecycleStateProvider =
    NotifierProvider<AppLifecycleNotifier, AppLifecycleState>(
      AppLifecycleNotifier.new,
    );

class AppLifecycleNotifier extends Notifier<AppLifecycleState> {
  @override
  AppLifecycleState build() => AppLifecycleState.resumed;

  void update(AppLifecycleState state) {
    if (state == this.state) return;
    this.state = state;
    // 同步非 riverpod 侧的全局标志：Notifier 若 listen 本 Provider
    // 会因依赖变化被整体重建（state 重置），播放器等长生命周期对象
    // 改走 [AppUiVisibility] 直连通知。
    AppUiVisibility.set(state != AppLifecycleState.resumed);
  }
}

/// 应用可见性的进程级标志（功耗计划 PW-03）。
///
/// 供 PlayerNotifier 等长生命周期对象直连订阅：
/// 走 Provider.listen 会把依赖变化升级为 Notifier 重建，
/// 导致播放状态被无谓重置；此标志以普通回调分发，无重建语义。
class AppUiVisibility {
  AppUiVisibility._();

  static bool _degraded = false;

  /// true = 应用不可见（息屏/后台/桌面最小化），UI 刷新应降级。
  static bool get degraded => _degraded;

  static final Set<void Function(bool)> _listeners = <void Function(bool)>{};

  static void set(bool degraded) {
    if (degraded == _degraded) return;
    _degraded = degraded;
    for (final listener in List.of(_listeners)) {
      listener(degraded);
    }
  }

  static void addListener(void Function(bool degraded) listener) =>
      _listeners.add(listener);

  static void removeListener(void Function(bool degraded) listener) =>
      _listeners.remove(listener);
}

/// UI 刷新降级标志：true = 应用不可见，纯视觉刷新无意义。
final appUiDegradedProvider = Provider<bool>(
  (ref) => ref.watch(appLifecycleStateProvider) != AppLifecycleState.resumed,
);

/// 把 WidgetsBinding 生命周期事件接入 Provider 的观察者壳。
class AppLifecycleObserver extends ConsumerStatefulWidget {
  const AppLifecycleObserver({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLifecycleObserver> createState() =>
      _AppLifecycleObserverState();
}

class _AppLifecycleObserverState extends ConsumerState<AppLifecycleObserver>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref.read(appLifecycleStateProvider.notifier).update(state);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
