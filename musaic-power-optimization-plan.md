# Musaic 功耗优化计划书

> 文档版本：v1.0  
> 适用项目：Musaic 音乐拼图  
> 技术基线：Flutter 3.44+ / Dart 3.10+  
> 计划依据：`musaic-iteration-plan.md`（I2/I3 遗留项）、当前源码功耗热点审查  
> 计划原则：先度量后优化；事件驱动替代轮询；前台/后台分级供给资源；不在可感知体验上妥协；每项任务可验证、可回滚。

---

## 1. 计划摘要

Musaic 的核心使用场景是「长时间后台播放」，这正是移动设备功耗最敏感的场景。播放器类应用功耗失控的典型后果是：系统省电策略限制后台活动、用户察觉发热与掉电后卸载。

当前主要功耗风险（均已在代码中定位证据，见 §4）：

1. 播放进度定时器 10Hz 恒定运行，暂停与后台期间仍持续唤醒 CPU。
2. 睡眠定时器倒计时以 1Hz `setState` 重建整个播放页，最长持续 60 分钟。
3. MiniPlayer 实时模糊默认开启且全页面常驻，GPU 无法进入低功耗状态。
4. 全应用没有任何 `AppLifecycleObserver`，后台/息屏后所有 UI 刷新照常执行。
5. 封面取色在主 isolate 对全尺寸图片执行，切歌时产生 CPU 尖峰。
6. 歌词逐字高亮 10Hz 重建，后台/息屏期间无意义地执行。

本计划将这些工作分为三个优先级：

```text
PW-A 息屏与后台纪律（P0：定时器与生命周期纪律）
→ PW-B 前台 GPU 与 CPU 尖峰（P1：模糊、取色、歌词刷新分级）
→ PW-C 网络与平台专项（P1/P2：蜂窝降质、心跳校准、桌面端、度量看护）
```

---

## 2. 功耗模型：按场景分解

优化目标不是笼统的「省电」，而是让每个场景只消耗该场景必需的资源。

| 场景 | 必需工作 | 禁止工作 |
|---|---|---|
| 前台播放 | 音频解码、进度条/歌词刷新、单处实时模糊 | 全页级 1Hz 重建、主 isolate 重计算 |
| 前台暂停 | 无周期任务 | 任何 10Hz/1Hz 定时唤醒 |
| 后台播放（息屏） | 音频解码、断点快照（≥15s 节流）、系统媒体同步 | 全部 UI 状态刷新、歌词高亮、倒计时重建 |
| 后台暂停 | 无（前台服务应退出，`androidStopForegroundOnPause` 已开启） | 位置轮询、UI 刷新 |
| 空闲未播放 | 无周期任务 | 任何常驻 Timer |
| 搜索/聚合请求 | 并行请求（先到先展示，已实现） | 无超时的长请求拖亮射频 |
| 本地扫描 | 后台 isolate 有界解析（已实现） | UI isolate 解析、无上限并发 |
| WebView 登录 | 用户交互期间的页面渲染 | 登录完成后的 WebView 残留存活 |

---

## 3. 与现有迭代计划的关系

| 已立项项 | 本计划视角的处理 |
|---|---|
| B21 位置 Timer 空闲唤醒（I3 §10.3） | 并入 PW-01，扩展为「播放状态 + 应用前后台」双维度生命周期 |
| B11 PlayerPage 重建（I3 §10.2） | 精确 select 已完成；PW-02 处理其遗留的睡眠倒计时全页 setState |
| §10.7 动画和模糊（I3） | PW-04 落实「列表页关闭实时模糊 / 低端设备默认关」 |
| §9.3 本地扫描流水线 | 已完成 isolate 化；PW-08 只补充电/低电量策略 |
| B22 Provider 长期累积（I2/I3） | 已由 autoDispose 与缓存上限覆盖，本计划不重复立项 |

---

## 4. 现状基线（代码证据）

| # | 现状 | 证据位置 | 影响 |
|---|---|---|---|
| E1 | 播放进度 `Timer.periodic(100ms)` 在 Provider 构建时创建，仅在 dispose 取消；暂停时靠回调内 early-return 省工作，但唤醒本身照常发生 | `lib/features/player/player_notifier.dart:144` | 暂停/后台期间每秒 10 次 CPU 唤醒，阻止核心进入深度空闲 |
| E2 | 睡眠倒计时 `Timer.periodic(1s)` 内 `setState(() {})` 重建整个 PlayerPage | `lib/features/player/player_page.dart:53` | 15～60 分钟的定时期间，每秒一次全页重建（含模糊区域） |
| E3 | MiniPlayer `BackdropFilter(sigma 18)` 全页面常驻，且 `enableGlass` 默认为 true | `lib/features/player/mini_player.dart:104`、`lib/features/settings/settings_providers.dart:24` | 列表页滚动时 GPU 持续执行实时模糊 |
| E4 | 全应用无任何 `AppLifecycleState` 监听 | 全库 grep 无 `WidgetsBindingObserver` | 息屏/后台后 UI 刷新、歌词高亮、倒计时照常执行 |
| E5 | 封面取色 `PaletteGenerator.fromImageProvider` 在主 isolate、对原始尺寸封面执行 | `lib/features/theme/dynamic_color_provider.dart:48` | 每次切歌一次 CPU 尖峰，后台播放时同样触发 |
| E6 | 歌词逐字行内 `ref.watch(position)`，10Hz 重建 RichText | `lib/features/lyrics/presentation/lyrics_view.dart`（_WordHighlightLine） | 前台必要，但息屏后仍随 E1 继续执行 |
| E7 | MQTT 心跳 5～60s 自适应（keepAlive/2，下限 5s） | `lib/sources/qqmusic/qq_mqtt.dart:198` | 基本合理；重连退避策略需要核对 |
| E8 | 断点续播写盘 15s 节流 | `lib/features/player/player_notifier.dart:596`（_persistResume） | 已达标，保持 |
| E9 | Android 前台服务配置正确（mediaPlayback 类型 + WAKE_LOCK），`androidStopForegroundOnPause: true` | `android/app/src/main/AndroidManifest.xml:6-8,53`、`lib/features/player/audio_handler.dart` | 已达标，保持并回归 |
| E10 | 图片缓存数量/字节上限与本地封面解码尺寸已限制 | `lib/main.dart`（imageCache）、四处 `cacheWidth`/`memCacheWidth` | 已达标 |
| E11 | 网络超时可调、账号校验已错峰 | `lib/core/network/network_config.dart`、`account_notifier.dart` | 已达标 |

---

## 5. 任务清单

### 5.1 PW-A 息屏与后台纪律（P0）

| ID | 任务 | 方案 | 涉及 | 验收方式 |
|---|---|---|---|---|
| PW-01 | 位置 Timer 生命周期化 | 取消 build 期常驻 `Timer.periodic`：播放状态变为 playing 时创建、暂停/停止/队列清空时取消；恢复播放重建。Timer 回调仅做状态采样 | `player_notifier.dart` | 暂停后 perfetto/Instruments 中无 10Hz 唤醒；恢复播放进度条正常 |
| PW-02 | 睡眠倒计时局部化 | 删除全页 `setState`：倒计时抽取为独立 `_SleepCountdownText` widget 自持 Timer，秒级只重建自身文本；定时取消即销毁 Timer | `player_page.dart` | Widget 测试：定时期间其余组件不重建（rebuild 计数）；倒计时文本仍每秒走字 |
| PW-03 | 应用生命周期接入 | `PlayerNotifier`（或 app shell）注册 `WidgetsBindingObserver`：进入 hidden/paused 时置「UI 刷新降级」标志——位置状态更新降为 1Hz（仅供断点快照与恢复进度），歌词高亮、倒计时 UI 完全跳过；回 resumed 恢复原频率 | `main.dart` 或 app shell、`player_notifier.dart`、`lyrics_view.dart` | 息屏播放 5 分钟：日志计数证明 UI 刷新为 0、快照仍 ≥15s 落盘；回前台 UI 立即正确 |
| PW-04 | 空闲纪律回归 | 队列清空/停止时确认无任何周期 Timer 存活（PW-01/PW-02 完成后的整体断言） | `player_notifier.dart` | 测试：`stop` 后枚举 notifier 内部 Timer 全为 null；真机空闲 10 分钟无 CPU 唤醒 |

### 5.2 PW-B 前台 GPU 与 CPU 尖峰（P1）

| ID | 任务 | 方案 | 涉及 | 验收方式 |
|---|---|---|---|---|
| PW-05 | MiniPlayer 模糊降级 | 列表/浏览类页面（首页、搜索、资料库路由下）MiniPlayer 用预烘焙静态模糊封面或纯色；仅 PlayerPage 保留唯一实时模糊。实现：MiniPlayer 增加「简化玻璃」模式，依据当前路由判定 | `mini_player.dart`、`app_shell.dart` | GPU 帧耗时对比（DevTools）：列表滚动时模糊着色器执行次数为 0 |
| PW-06 | 玻璃默认值分级 | 移动端默认关闭玻璃（`enableGlass` 默认 false），桌面端保持默认开启；设置页保留开关并注明功耗影响 | `settings_providers.dart`、`settings_page.dart` | 全新安装移动端默认无实时模糊；用户开启后生效且重启保持 |
| PW-07 | 取色降采样与隔离 | 取色输入先用 `cacheWidth: 64` 解码缩略图再喂 `PaletteGenerator`；必要时迁入 isolate。同一封面取色结果缓存（coverUrl → palette），autoDispose 上限保留 | `dynamic_color_provider.dart` | 切歌时主 isolate 无 >8ms 的连续占用（Timeline）；同封面二次切歌不重算 |
| PW-08 | 歌词刷新分级 | 逐字行维持 10Hz 仅当前词重建（现状）；息屏/后台由 PW-03 标志整体跳过；逐行歌词（LRC）行内零重建（现状保持）。避免新增任何全局 position watch | `lyrics_view.dart` | Widget 重建计数：非当前行在进度推进时零重建（已有行为回归） |

### 5.3 PW-C 网络与平台专项（P1/P2）

| ID | 任务 | 方案 | 涉及 | 验收方式 |
|---|---|---|---|---|
| PW-09 | 蜂窝网络音质降档 | 新增设置「蜂窝网络自动降质」（默认开）：播放前请求经系统网络判断（`connectivity_plus` 的 Wi-Fi 判定），蜂窝时按音质档位降一级（320→192→128）；用户手动档位优先于降档 | `settings_providers.dart`、`player_notifier.dart`（resolveStream 前）、`pubspec.yaml` | 单元测试降档选择逻辑；真机切换 Wi-Fi/蜂窝观察日志生效 |
| PW-10 | MQTT 心跳与重连核对 | 心跳区间 5～60s 已自适应；核对断线重连是否指数退避（1s→2s→4s→…→上限 60s），避免弱网下高频重连拖亮射频；连接空闲且无播放时评估是否断开 | `qq_mqtt.dart` | 坏包/断网重连测试（已有 qq_mqtt_test 扩展）：重连间隔序列符合退避曲线 |
| PW-11 | 封面 URL 归一化 | 网易云/QQ 封面 URL 带 size/参数变体导致 cache miss 重复下载：请求前归一化到统一尺寸参数，提高磁盘缓存命中 | `cover_network.dart` 或渠道解析层 | 同一专辑封面二次出现时无网络请求（日志/缓存命中计数） |
| PW-12 | 扫描功耗策略 | 扫描已 isolate 化；补充分段让步（每批回传间 `Future.delayed(Duration.zero)` 已天然让步，确认）；低电量（`battery_plus` ≤20% 且未充电）时推迟「强制重扫」并提示 | `local_file_source.dart`、`local_music_settings_page.dart` | 低电量模拟下重扫入口出现提示；扫描期间 UI isolate 无解析（回归） |
| PW-13 | 桌面端空闲友好 | 最小化/失焦时暂停倒计时 UI 与模糊渲染（`windowManager` 事件接入 PW-03 同一标志）；确认无常驻高精度 Timer，保持 App Nap / Windows 现代待机友好 | `app_shell.dart`、`main.dart` | macOS `powermetrics` 采样：最小化挂起 10 分钟 CPU 占用≈0 |
| PW-14 | 功耗度量看护 | `docs/benchmarks.md` 增设「功耗基线」章节：记录各场景 CPU 唤醒率、前台 GPU 帧耗时、后台 30 分钟耗电百分比；每次发布前按 §6 SOP 复测 | `docs/benchmarks.md` | 文档存在且含首批实测数据（非目标值） |

---

## 6. 度量方法（SOP）

功耗无法在 CI 中自动回归，采用「手动 SOP + 代码级断言」组合：

| 平台 | 工具 | 关键指标 |
|---|---|---|
| Android | Android Studio Profiler Energy / `adb shell dumpsys batterystats` / perfetto | 应用 CPU 时间、唤醒次数（wakeup count）、前台服务存活时长 |
| iOS | Xcode Instruments → Energy Log | CPU 唤醒（timer wakeups）、网络活动、GPU 利用率 |
| macOS | `powermetrics`（sudo，本机手动执行）或 Activity Monitor 能耗影响 | 能耗影响评分、CPU 时间 |
| Windows | 任务管理器功耗使用情况 | 功耗使用等级（Very Low～Very High） |

代码级断言（进入 CI 的部分）：

- Timer 生命周期单元测试：播放/暂停/停止/后台四态切换后，notifier 内活跃 Timer 数量符合预期（0 或 1）。
- Widget 重建计数测试：睡眠定时期间 PlayerPage 非 Countdown 组件零重建。
- 降档逻辑纯函数测试：Wi-Fi/蜂窝 × 手动档位矩阵。

## 6.1 目标值（发布前必须实测并记录）

| 场景 | 指标 | 目标 |
|---|---|---|
| 前台暂停 10 分钟 | 周期性 CPU 唤醒 | 0 次/秒 |
| 后台息屏播放 30 分钟 | UI 刷新任务 | 0 个（仅音频解码 + 快照） |
| 后台息屏播放 30 分钟 | 应用耗电占比 | 低于系统「媒体播放」基准应用 ±20% |
| 列表页滚动 | 模糊着色器执行 | 0 次/帧（简化玻璃模式） |
| 蜂窝播放 | 默认码率 | ≤192kbps（用户可改） |
| 切歌瞬间 | 主 isolate 单段占用 | <8ms |

---

## 7. 出口标准

1. 暂停与空闲状态下应用无任何周期性 CPU 唤醒（断点快照除外，且 ≥15s 节流）。
2. 后台/息屏播放时零 UI 刷新：歌词、进度条、倒计时全部跳过，音频与系统媒体同步不受影响。
3. 全应用实时 `BackdropFilter` 同时最多 1 个（仅 PlayerPage），且移动端默认关闭。
4. 取色不在主 isolate 处理原始尺寸图片，同封面结果有缓存。
5. 蜂窝网络默认降档播放，设置可覆盖。
6. `docs/benchmarks.md` 含 §6.1 全部场景的实测数据。
7. 不出现因功耗优化引入的体验回退：进度条/歌词/倒计时在前台的展示与现状一致。

---

## 8. 风险与回滚

| 风险 | 概率 | 影响 | 应对 |
|---|---|---|---|
| Timer 生命周期化引入进度刷新遗漏（切歌/seek 后停更） | 中 | 高 | 保留 `_tickPosition` 的幂等去重逻辑；seek 后强制 tick 一次；状态机单测覆盖 |
| 生命周期标志误判（后台误判为前台）导致 UI 卡住 | 低 | 中 | 标志仅在 hidden/paused 生效，resumed 无条件恢复；回前台强制 tick 一次 |
| 模糊降级造成视觉跳变（页面切换时 MiniPlayer 质感变化） | 中 | 低 | 简化玻璃用预烘焙模糊图过渡；接受度用户可开关 |
| 蜂窝降档误判（桌面/以太网被当蜂窝） | 低 | 中 | 仅对移动平台启用判断；判定失败默认不降档 |
| runZonedGuarded/Observer 与现有 Provider 时序冲突 | 低 | 中 | 生命周期观察放 app shell，独立于 Provider 构建 |
| 息屏后系统杀 isolate 定时器导致快照缺失 | 低 | 低 | 快照本就节流 15s，且切歌/暂停/退出均有 force 落盘 |

## 8.1 回滚策略

- PW-01/PW-02 为纯行为重构，单提交可独立 revert。
- PW-05/PW-06 由既有 `enableGlass` 开关兜底，出问题可热改默认值。
- PW-09 由独立设置项控制，默认行为可一键回退为「不降档」。

---

## 9. 推荐执行顺序

```text
第 1 步（P0，1～2 天）
  PW-01 位置 Timer 生命周期化
  PW-02 睡眠倒计时局部化
  PW-03 应用生命周期接入（UI 降级标志）

第 2 步（P1，2～3 天）
  PW-04 空闲纪律断言与回归
  PW-05 MiniPlayer 模糊降级
  PW-06 玻璃默认值分级
  PW-07 取色降采样与缓存

第 3 步（P1/P2，2～3 天）
  PW-09 蜂窝降档
  PW-10 MQTT 退避核对
  PW-11 封面 URL 归一化

第 4 步（P2，1～2 天）
  PW-12 扫描功耗策略
  PW-13 桌面端空闲友好
  PW-14 功耗基线文档与首批实测
```

每个任务遵循 `musaic-iteration-plan.md` §19 的 Definition of Done：实现 + 边界处理 + 单测/Widget 测试 + analyze/test 全绿 + 实测数据入文档。

---

## 10. 结语

功耗优化的本质是把「资源供给」与「可感知价值」对齐：屏幕看不见的地方不刷新，用户没点播放的地方不定时唤醒，射频能合并就合并。Musaic 已完成的性能专项（重建隔离、缓存上限、扫描 isolate 化）恰好是功耗优化的地基；本计划在其上补齐「后台纪律」与「平台分级」两块短板，让长时间播放成为产品的长处而非负担。
