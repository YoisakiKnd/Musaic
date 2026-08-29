# Musaic 性能与功耗基线

> 文档目的：记录实测数据而非目标值（迭代计划 I0-05 / 功耗计划 PW-14）。  
> 更新约定：每次发布前按下方 SOP 复测并追加一行记录；数据与日期、构建号绑定。

---

## 0. 首轮实测记录（2026-08-29 · Pixel 8 AVD · API 35 arm64 · debug 构建）

> 模拟器 CPU 数据反映行为纪律（唤醒/占空），绝对功耗以真机为准。

| 指标 | 实测 | 结论 |
|---|---|---|
| 冷启动首帧（debug/JIT） | 2.64s（Displayed） | debug 基线，release 待实测 |
| 前台播放 15s 进程 CPU | 10 ticks（0.10s） | WAV 解码轻量 |
| 后台播放 15s 进程 CPU | 2 ticks（0.02s） | **后台较前台 -80%**：息屏 UI 刷新降级生效（PW-03） |
| 暂停 30s / 60s 进程 CPU | 3 / 0 ticks | **暂停零周期唤醒**（PW-01 达成） |
| 暂停后前台服务 | `isForeground=false`（即退） | `stopForegroundOnPause` 生效 |
| 媒体键 pause/play/next | 全链路生效 | 系统媒体集成（MainActivity 修复后） |
| 队列尽头 | 通知转 PAUSED、服务退前台 | 「通知过期 PLAYING」Bug 已修复并回归 |
| 自动连播 | A→B→C 顺序推进 | QueueLogic 真机路径验证 |
| 断点续播 | 强杀进程重启后横幅恢复 C 曲 | ResumeRepository 真机验证 |
| 本地扫描 → 搜索 → 播放 | 3 文件全链路通过 | isolate 扫描真机验证 |
| Hive 数据跨 `install -r` | 收藏/历史/搜索历史保留 | 持久化验证 |

### 首轮实测发现并修复的 Bug

1. **MainActivity 继承错误**（P0）：继承了 `FlutterFragmentActivity` 而 audio_service 要求 `AudioServiceActivity`，导致 `AudioService.init` 抛 PlatformException 且被静默吞掉——通知栏/锁屏/媒体键全部失效。修复 + init 失败改为显式 debugPrint。
2. **队列尽头通知过期**：`next()` 在末曲后只重置应用内状态，系统会话停留过期 PLAYING、前台服务悬挂。修复：末曲后暂停 just_audio，会话/通知/前台同步。
3. **ListTile 诊断刷屏**（debug-only）：MiniPlayer（10Hz 重建 × ListTile）+ TrackTile 位于带背景容器内，每次重建触发「ink splashes may be invisible」。已设 `tileColor: Colors.transparent` 修复两处主源；残留偶发项（与续播快照状态相关、debug-only）待后续定位。
4. **网易云搜索无封面**（用户反馈）：搜索接口 `/api/search/get/web` 返回的 `album.picUrl` 实测恒为 null。修复：搜索后经 `/api/song/detail` 批量接口一次补全封面与专辑名（失败静默）。EMU 截图验证封面全部呈现。
5. **QQ 搜索无封面**（用户反馈，两因叠加）：① 补全响应解析 `as List?` 强转在 Map 响应时抛 TypeError、`??` 兜底永远不走——封面从未成功过；② PW-11 归一化误用 `R512x512M`（QQ CDN 无此档，404），已改 `R500x500M`。EMU 截图验证封面呈现（个别无专辑曲正确降级占位）。遗留：封面补全为逐曲并发请求，待按计划 §10.6 加 3~4 路并发限制。

---

## 1. 性能基线（构建/启动/流畅度）

| 指标 | 平台 | 目标 | 实测 | 日期 | 备注 |
|---|---|---|---|---|---|
| 冷启动首帧 | Android 中端机 | <1s | 待实测 | — | 迭代计划 §15.1 |
| 首页可交互 | Android 中端机 | <1.5s | 待实测 | — | |
| 列表滚动帧耗时 | Android 中端机 | <16.67ms | 待实测 | — | DevTools Timeline |
| 播放页进度条重建范围 | 全平台 | 仅进度条子树 | 已由精确 select 保证 | 2026-08 | 单元级由 widget 测试守护 |

## 2. 功耗基线（musaic-power-optimization-plan.md §6.1）

| 场景 | 指标 | 目标 | 实测 | 日期 | 工具 |
|---|---|---|---|---|---|
| 前台暂停 10 分钟 | 周期性 CPU 唤醒 | 0 次/秒 | 已由测试守护（定时器生命周期断言） | 2026-08 | fakeAsync 单测 |
| 后台息屏播放 30 分钟 | UI 刷新任务 | 0 个（仅音频+快照） | 待实测 | — | perfetto / Instruments Energy Log |
| 后台息屏播放 30 分钟 | 应用耗电占比 | 系统媒体基准 ±20% | 待实测 | — | batterystats |
| 列表页滚动 | 实时模糊着色器执行 | 0 次/帧 | 已达成（MiniPlayer 静态磨砂替代 BackdropFilter） | 2026-08 | 代码审查 |
| 蜂窝播放默认码率 | ≤192kbps | 已达成（蜂窝自动降质默认开启） | 2026-08 | 设置层矩阵单测 |
| 切歌瞬间主 isolate 占用 | <8ms | 待实测 | — | DevTools |

### 已落地的功耗行为（代码级保障）

- 位置轮询定时器仅在播放/加载期间存活；暂停与空闲零唤醒（PW-01，测试守护）。
- 应用不可见（息屏/后台/桌面最小化）时进度采样降为 1Hz，仅供断点快照（PW-03，测试守护）。
- 睡眠倒计时仅重建按钮自身文本，且后台期间 ticker 取消（PW-02，测试守护）。
- MiniPlayer 实时 BackdropFilter 已移除，改为 24px 微缩封面上采样的静态磨砂层（PW-05）。
- 移动端玻璃效果默认关闭、桌面端默认开启，用户可覆盖（PW-06，测试守护）。
- 封面取色输入固定 64×64 降采样，按封面 URL family 缓存（PW-07，前批次已达成）。
- 蜂窝网络自动降质默认开启，播放解析前按当前链路降一档（PW-09，矩阵单测）。
- 封面 URL 归一化（网易 param / QQ 路径尺寸）提升磁盘缓存命中（PW-11，单测）。
- QQ 扫码登录 MQTT：15 分钟有界流程、心跳 5～60s 自适应、无自动重连风暴（PW-10 核对结论：无需改码）。

## 3. 功耗测量 SOP

### Android

1. 构建并安装 release 包（`flutter build apk --release` + 签名门禁要求 key.properties）。
2. 复位统计：`adb shell dumpsys batterystats --reset`。
3. 执行目标场景（如息屏播放 30 分钟，音量固定、屏幕亮度固定）。
4. 导出：`adb bugreport bugreport.zip`，用 Battery Historian 打开查看应用 CPU 时间与 wakeup 计数。
5. 帧级分析：`adb shell perfetto -o /data/misc/perfetto-traces/trace --time 60s`，在 UI 线程确认无周期性任务。

### iOS

1. Xcode → Instruments → Energy Log 模板，连接真机运行 release 配置。
2. 场景执行期间观察 CPU Wakeups、Network Activity、GPU 行。
3. 息屏场景使用「Lock」按钮模拟锁屏后继续播放。

### macOS

1. `sudo powermetrics --samplers cpu_power -i 5000`（本机手动执行，记录能耗）。
2. 或 Activity Monitor「能耗影响」列；最小化挂起 10 分钟应≈0。

### Windows

1. 任务管理器 → 详细信息 → 「功耗使用情况」列。
2. 场景执行后记录等级（Very Low ～ Very High）。

## 4. 记录规范

- 每条实测数据必须附带：日期、构建号（pubspec version + git 短哈希）、设备型号、系统版本、电量区间（避免低电量省电策略干扰）。
- 数据劣化超过目标值 20% 时，先在迭代计划追加回归任务，再合并功能改动。
