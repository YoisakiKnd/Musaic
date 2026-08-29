# Musaic 项目迭代计划书

> 文档版本：v1.0  
> 适用项目：Musaic 音乐拼图  
> 技术基线：Flutter 3.29+、Dart 3.7+  
> 计划依据：`README.md`、`musaic-master-plan.md`、`musaic-improvement-plan.md` 与当前源码审查  
> 计划原则：先保护成果，再修复正确性；先稳定性能，再扩展功能；所有任务必须可验证、可回滚、可度量。

---

## 1. 计划摘要

Musaic 当前已经完成多渠道音乐播放器的主要功能骨架，具备本地音乐、网易云、QQ 音乐、酷狗、YTM 渠道，支持搜索、播放、歌词、队列、收藏、历史、歌单、账号登录和断点续播。

当前项目的主要问题不是功能数量不足，而是：

1. 发布和 CI 基线尚未稳定。
2. 播放器状态机、渠道网络层和数据导入缺少系统测试。
3. 本地扫描、备份处理和播放器 UI 存在明显性能风险。
4. 凭据、播放 URL、WebView Cookie 和部分 HTTP 请求存在安全边界问题。
5. 现有计划中部分功能已经实现，但状态标记与实际代码仍有漂移。
6. 当前工作树存在大量未提交修改，必须先建立可恢复基线。

本计划将迭代分为：

```text
I0 工程基线
→ I1 发布、安全与核心正确性
→ I2 存储、内存与本地库性能
→ I3 播放、搜索与界面流畅度
→ I4 渠道稳定性与内容完整度
→ I5 Beta 发布与长期维护
```

在 I0～I3 完成前，不建议继续大规模扩展自定义渠道、WebDAV 或复杂社交能力。

---

## 2. 项目定位与产品目标

### 2.1 产品定位

Musaic 是一个跨平台、多渠道、沉浸式音乐播放器：

- 聚合多个音乐来源。
- 每个渠道独立管理账号和凭据。
- 使用统一曲目模型和统一播放体验。
- 对本地音乐提供可靠的扫描、标签、封面和歌词能力。
- 在播放器区域提供沉浸式视觉和逐字歌词体验。

### 2.2 V1 核心目标

| 目标 | 说明 |
|---|---|
| 能搜索 | 单渠道和聚合搜索，失败渠道可独立重试 |
| 能播放 | 远程和本地歌曲均可播放 |
| 能持续播放 | 队列、随机、循环、系统媒体控制可用 |
| 能管理数据 | 收藏、历史、自建歌单和备份可靠 |
| 能登录 | 各渠道账号状态、凭据和过期处理正确 |
| 能看歌词 | YRC、TTML、LRC 按降级策略工作 |
| 能跨平台 | Android、iOS、macOS、Windows 完成核心回归 |
| 能长期运行 | 播放 30 分钟无明显内存增长和持续掉帧 |

### 2.3 V1 非目标

以下内容不作为 V1 发布阻塞项：

- 社交、评论、动态和用户社区。
- 规避版权限制的下载功能。
- 服务端账号系统。
- 未经安全设计的自定义 JavaScript 渠道插件。
- Web 端正式发布。
- 在没有平台能力验证前承诺所有高级音频功能。

---

## 3. 当前基线

### 3.1 技术和代码结构

| 项目 | 当前状态 |
|---|---|
| 源码规模 | `lib/` 约 71 个 Dart 文件 |
| 测试规模 | `test/` 约 16 个 Dart 测试文件 |
| 状态管理 | Riverpod Notifier、Provider、StreamProvider |
| 路由 | go_router |
| 网络 | Dio，每个渠道独立客户端 |
| 本地数据 | Hive + JSON |
| 凭据 | flutter_secure_storage |
| 音频 | just_audio + audio_service |
| UI | Material 3 基础组件 + 播放器沉浸式视觉 |
| 平台 | Android、iOS、macOS、Windows |
| CI | 当前未建立有效的 CI 门禁 |
| 集成测试 | 当前缺少完整主链路集成测试 |
| Golden 测试 | 当前未引入可持续维护的方案 |

### 3.2 已有能力

- `MusicSource` 统一渠道抽象。
- `SourceRegistry` 渠道注册和解析。
- `QrLoginCapable`、`PasswordLoginCapable`、`WebLoginCapable` 等能力接口。
- `PlayerNotifier` 队列和播放状态管理。
- `MusaicAudioHandler` 系统媒体集成。
- LRC、YRC、TTML 解析。
- Hive 收藏、历史、歌单存储。
- 本地 ID3v1/ID3v2 解析和内嵌封面。
- 资料库 JSON 备份和导入。
- 网络超时、音质、歌词偏移和倍速设置。

### 3.3 当前主要缺口

- Release 签名配置不完整。
- 核心文件存在未提交和未跟踪风险。
- 没有完整 CI、集成测试和覆盖率门禁。
- 播放器状态机缺少测试。
- 本地扫描仍在 UI isolate 中执行。
- 播放页可能因位置更新进行大范围重建。
- 搜索首屏仍等待全部渠道。
- WebView Cookie 过滤、播放 URL 日志和酷狗请求安全需要整改。
- Hive 启动损坏恢复、备份导入回滚尚未完成。

---

## 4. 总体架构目标

### 4.1 目标分层

```text
Presentation
    ↓
Application
    ↓
Domain contracts
    ↓
Data repositories / Network clients
    ↓
Source implementations / Platform adapters
```

### 4.2 依赖规则

1. UI 只依赖应用层和领域模型。
2. UI 不直接 import `lib/sources/` 具体实现。
3. 渠道实现不依赖 UI。
4. `core` 不依赖 `features`，组合根可以作为唯一例外。
5. 凭据只能通过 `AccountRepository` 或其后续抽象进出安全存储。
6. 播放状态只能由 `PlayerNotifier` 维护，`AudioHandler` 只负责系统媒体适配。
7. 所有外部网络响应必须经过渠道解析器转换为领域模型。
8. 所有外部输入必须在进入领域层前完成格式、长度和安全校验。

### 4.3 目标目录

```text
lib/
├── app/
│   ├── bootstrap/
│   ├── composition_root/
│   └── router/
├── core/
│   ├── auth/
│   ├── error/
│   ├── logging/
│   ├── model/
│   ├── network/
│   ├── result/
│   ├── source/
│   └── theme/
├── features/
│   ├── auth/
│   │   ├── application/
│   │   ├── data/
│   │   ├── domain/
│   │   └── presentation/
│   ├── library/
│   ├── lyrics/
│   ├── player/
│   ├── search/
│   ├── settings/
│   └── theme/
└── sources/
    ├── kugou/
    ├── local/
    ├── netease/
    ├── qqmusic/
    └── ytm/
```

大型渠道文件后续拆为：

```text
source.dart
api_client.dart
parser.dart
auth_flow.dart
capabilities.dart
```

---

## 5. 版本路线图

| 版本 | 目标 | 主要内容 |
|---|---|---|
| 0.1.0 | 当前开发基线 | 现有多渠道、播放、歌词、账号和资料库能力 |
| 0.2.0 | 稳定化版本 | 发布安全、CI、核心 Bug、播放器和数据测试 |
| 0.3.0 | 性能版本 | 启动、本地扫描、存储、内存、搜索和 UI 流畅度 |
| 0.4.0 | 内容完整版本 | YTM 歌词、QQ 歌单、备份增强、诊断工具 |
| 0.5.0 | Beta 版本 | 平台回归、集成测试、发布包和用户反馈机制 |
| 1.0.0 | 首个稳定版 | 核心功能冻结、文档完整、性能和安全指标达标 |
| 1.1.x | 数据自主 | WebDAV 同步、冲突处理、导入导出增强 |
| 1.2.x | 内容扩展 | 艺人/专辑、相似歌曲、渠道收藏写回 |
| 2.0.0 | 插件化演进 | 自定义渠道、投屏、Android Auto、高级音频能力 |

---

# 6. 迭代阶段 I0：工程基线

## 6.1 目标

建立可恢复、可构建、可测试、可发布的工程起点。

## 6.2 任务清单

| ID | 任务 | 代码/配置范围 | 优先级 |
|---|---|---|---|
| I0-01 | 整理未提交和未跟踪文件 | Git 工作树、`lib/`、`test/` | 🔴 |
| I0-02 | 确认 Android/macOS 可启动 | `android/`、`macos/` | 🔴 |
| I0-03 | 恢复最小 CI | `.github/workflows/ci.yml` | 🔴 |
| I0-04 | 增加格式和静态分析门禁 | `analysis_options.yaml`、CI | 高 |
| I0-05 | 建立性能基线文档 | `docs/benchmarks.md` | 高 |
| I0-06 | 统一文档入口 | `docs/`、README | 中 |
| I0-07 | 引入版本号单一来源 | `pubspec.yaml`、关于页 | 中 |

## 6.3 CI 第一版

```text
依赖安装
→ dart format --set-exit-if-changed
→ flutter analyze
→ flutter test
```

CI 失败条件：

- 格式化不通过。
- 静态分析有错误或警告。
- 任意单元/Widget 测试失败。
- 依赖无法在干净环境解析。

## 6.4 出口标准

- 所有核心源码和测试文件都在版本控制中。
- 干净 clone 可以执行 `flutter pub get`。
- CI 可以完成 format、analyze、test。
- Android Debug 构建成功。
- macOS Debug 构建成功。
- 当前性能数据被记录，而不是只保留目标值。

---

# 7. 迭代阶段 I1：发布、安全与核心正确性

## 7.1 目标

修复会导致无法发布、数据泄露或核心功能错误的问题。

## 7.2 发布安全

### Android Release 签名

涉及：

- `android/app/build.gradle.kts`
- `key.properties.example`
- CI Secret 配置

实施方案：

```text
本地存在 key.properties → 使用本地 release keystore
本地不存在 key.properties → Debug 构建保持可用
CI 环境 → 从 Secret 生成临时 key.properties
```

禁止：

- 提交 keystore。
- 提交真实密码。
- Release 继续使用 debug 签名。

### 依赖可复现

移除依赖本机 pub cache 的修改脚本，优先使用：

- `dependency_overrides` 指向已修复 fork。
- 固定经过验证的依赖版本。
- 在 CI 中执行干净依赖安装。

## 7.3 凭据与日志安全

涉及：

- `lib/features/auth/data/account_repository.dart`
- `lib/core/network/source_auth_interceptor.dart`
- `lib/features/player/player_notifier.dart`
- `lib/features/auth/presentation/web_login_page.dart`

实施方案：

1. 单渠道凭据使用一个安全 Blob。
2. YTM Cookie 按域名和字段白名单过滤。
3. 禁止记录完整播放 URL。
4. 禁止将 Token 和 UserID 放入不必要的 GET 查询串。
5. 统一 `AppLogger`，自动过滤 `Cookie`、`Authorization`、`token`、`passwd` 等字段。
6. 网络错误只记录渠道、错误类型、HTTP 状态和请求耗时。

## 7.4 播放核心正确性

涉及：

- `lib/features/player/player_notifier.dart`
- `lib/features/player/audio_handler.dart`
- `lib/features/player/domain/queue_logic.dart`

实施方案：

- `publishQueue` 显式接收 `queueIndex`。
- 队列移动、删除、清空、随机重排后立即同步系统队列。
- `playAt`、`next`、`previous`、`removeFromQueue` 使用播放操作串行队列。
- 保留 `_loadSeq` 作为旧请求失效机制。
- 对 `seekTo`、恢复快照和队列索引做边界校验。
- 区分手动上一首和系统上一首的行为。

## 7.5 启动容错

涉及：

- `lib/main.dart`
- `lib/features/auth/application/account_notifier.dart`

实施方案：

- Hive Box 分组打开，单个损坏 Box 不阻塞首页。
- 损坏数据先备份，再重建 Box。
- 账号校验错峰执行。
- 通知权限不阻塞首帧。
- AudioService 延迟到首次播放初始化。

## 7.6 出口标准

- Android Release 使用独立签名。
- 干净环境可以构建。
- 日志扫描不发现敏感字段。
- 队列操作和系统媒体队列索引一致。
- 有效 Cookie、失效 Cookie、断网三种账号状态行为正确。
- Hive 损坏时应用仍可以进入首页。

---

# 8. 迭代阶段 I2：存储专项

## 8.1 目标

降低数据读写成本，保证导入导出安全，并控制磁盘占用。

## 8.2 存储分层

| 数据 | 方案 | 限制 |
|---|---|---|
| 认证凭据 | Keychain/Keystore/DPAPI | 只保存必要字段，不同步 |
| 账号资料 | Hive | 版本化、可恢复 |
| 收藏 | Hive Key-Value | Key 为 `sourceId:trackId` |
| 历史 | 时间戳索引 | 最大 200 条 |
| 歌单 | 短期 Hive，长期可迁移 SQLite | 批量操作、并发保护 |
| 网络封面 | 自定义 CacheManager | 最大 100 MB |
| 本地封面 | 缓存目录 | 最大 256 MB |
| 日志 | 环形文件 | 最大 5 MB、自动轮转 |
| 备份 | 用户指定文件 | 临时文件完成后原子替换 |

## 8.3 历史记录优化

涉及：

- `lib/features/library/data/library_repository.dart`

从当前“每次播放后全表解码、排序、删除”调整为：

```text
删除同曲旧索引
→ 生成时间戳 Key
→ 写入新记录
→ 按 Key 删除最旧记录
```

要求：

- 相同歌曲重复播放时只保留最新记录。
- 导入历史保留原始时间。
- 旧格式启动时迁移一次。
- 迁移失败不删除旧数据。

## 8.4 歌单优化

短期保留现有 JSON 结构，但必须：

- 所有批量操作使用 `addManyToPlaylist`。
- 禁止循环调用 `addToPlaylist`。
- 对歌单名称进行 trim、长度和空值校验。
- 对同一歌单增加异步互斥锁。
- 大歌单写入前构造完整临时数据。

长期结构：

```text
playlist_metadata
playlist_tracks
```

当歌单规模或同步需求明显扩大后，再迁移到 SQLite 或其他结构化本地数据库。

## 8.5 凭据 Blob 迁移

推荐键名：

```text
musaic.credentials.netease
musaic.credentials.qqmusic
musaic.credentials.kugou
musaic.credentials.ytm
```

Blob 示例：

```json
{
  "version": 1,
  "credentials": {
    "MUSIC_U": "..."
  },
  "updatedAt": "2026-08-28T12:00:00Z"
}
```

迁移原则：

1. 优先读取新格式。
2. 新格式不存在时读取旧格式。
3. 转换并写入新格式。
4. 新格式验证成功后再删除旧字段。
5. 迁移失败保留旧数据并提示用户。

## 8.6 备份优化

涉及：

- `lib/features/library/data/backup_service.dart`
- `lib/features/settings/settings_page.dart`

导出：

```text
读取快照
→ 大数据量时放入 isolate 编码
→ 写入临时文件
→ flush
→ 原子 rename
```

导入：

```text
读取文件
→ 校验文件大小和 schema
→ 完整解析到临时对象
→ 校验曲目、歌单和历史结构
→ 创建事务快照
→ 批量写入
→ 失败则恢复事务快照
```

## 8.7 缓存清理

新增 `StorageMaintenanceService`，提供：

- 查看各类缓存大小。
- 清理网络封面。
- 清理本地封面。
- 清理诊断日志。
- 清理临时备份。
- 重建本地封面缓存。
- 显示清理前后空间变化。

## 8.8 出口标准

- 认证信息不进入普通文件和同步备份。
- 历史添加不再每次全表排序。
- 500 首歌单批量写入只发生一次核心写入。
- 备份导入失败时本地数据保持不变。
- 网络封面缓存不超过 100 MB。
- 本地封面缓存不超过 256 MB。
- 清理缓存不会删除收藏、历史和歌单。

---

# 9. 迭代阶段 I2：内存专项

## 9.1 图片缓存

涉及：

- `lib/features/home/home_page.dart`
- `lib/features/player/player_page.dart`
- `lib/features/shared/widgets/track_tile.dart`
- `lib/features/theme/dynamic_color_provider.dart`

统一限制：

```dart
PaintingBinding.instance.imageCache.maximumSize = 300;
PaintingBinding.instance.imageCache.maximumSizeBytes = 100 * 1024 * 1024;
```

建议解码尺寸：

| 场景 | 宽度 |
|---|---:|
| 搜索列表 | 128 |
| 最近播放卡片 | 264 |
| MiniPlayer | 192 |
| 播放器封面 | 512 |
| 系统媒体 | 不超过 512 |

要求：

- `Track` 只保存封面 URI。
- ID3 解析完成后释放原始图片字节。
- 图片加载失败必须有轻量占位图。
- 同一个封面不可因不同组件反复加载原图。

## 9.2 Provider 生命周期

评估并优先使用 `autoDispose`：

- `coverPaletteProvider`。
- `lyricsProvider`。
- 搜索会话 Provider。
- 远程歌单 Provider。
- 二维码登录流程 Provider。

对长生命周期 Provider 设置数量或时间上限，防止切换歌曲后缓存无限增长。

## 9.3 本地扫描内存模型

目标流水线：

```text
目录遍历
→ 路径队列
→ 4 路有界解析
→ 每 50～100 首回传
→ 释放标签和封面字节
→ 更新索引
```

禁止：

- 一次性读取整个音频文件。
- 在内存中保存全部原始封面。
- 扫描任务无限制递归。
- 对相同文件反复读取 ID3。

## 9.4 播放器内存隔离

将播放器拆分为：

```text
PlayerBackground
PlayerCover
PlayerProgress
PlayerControls
LyricsPanel
QueueButton
SleepTimerButton
```

背景、封面、歌词和控制区分别使用 `RepaintBoundary`。播放进度更新不得导致封面和背景重新创建。

## 9.5 出口标准

- 播放 30 分钟内存不持续线性增长。
- 常规播放内存目标小于 150 MB。
- 连续切换 100 首歌曲后旧歌词和封面可以释放。
- 本地扫描期间不保存所有音频和图片字节。
- 图片缓存有明确数量和字节限制。

---

# 10. 迭代阶段 I3：流畅度专项

## 10.1 启动流畅度

涉及：

- `lib/main.dart`
- `lib/core/di/app_providers.dart`

目标流程：

```text
Flutter binding
→ 最小配置
→ runApp
→ 首帧后打开普通 Box
→ 后台恢复账号状态
→ 首次播放时初始化 AudioService
→ 首次需要时请求通知权限
```

启动阶段禁止：

- 通知权限弹窗。
- 本地音乐扫描。
- 所有渠道网络校验。
- 大型备份解析。
- 播放器封面取色。

目标：

- 首帧小于 1 秒。
- 首页可交互小于 1.5 秒。

## 10.2 PlayerPage 重建优化

涉及：

- `lib/features/player/player_page.dart`
- `lib/features/lyrics/presentation/lyrics_view.dart`

将整页监听改为精确选择器：

```dart
final currentTrack = ref.watch(
  playerNotifierProvider.select((state) => state.current),
);

final position = ref.watch(
  playerNotifierProvider.select((state) => state.position),
);

final playing = ref.watch(
  playerNotifierProvider.select((state) => state.playing),
);
```

组件监听要求：

| 组件 | 只监听 |
|---|---|
| 背景 | 当前歌曲 |
| 封面 | 当前歌曲 |
| 进度条 | position、buffered、duration |
| 播放按钮 | playing |
| 队列按钮 | queue.length |
| 歌词 | 当前歌词索引和当前词进度 |
| 定时器 | sleep 状态 |

## 10.3 位置刷新策略

当前 100ms 定时器需要调整为按播放状态生命周期管理：

```text
播放 → 创建 Timer
暂停 → 取消 Timer
停止 → 取消 Timer
恢复 → 重新创建 Timer
销毁 → 取消 Timer
```

建议刷新频率：

| 模块 | 频率 |
|---|---:|
| 播放进度条 | 100 ms |
| 当前歌词词高亮 | 50～100 ms |
| MiniPlayer | 250 ms |
| 背景/封面 | 仅切歌时 |
| 历史列表 | 数据变化时 |

## 10.4 歌词渲染优化

第一阶段：

- 非当前行只监听行索引。
- 当前行单独监听 position。
- 缓存 TextSpan 和行布局。
- 歌词 Provider 使用生命周期回收。

第二阶段：

- 使用 `CustomPainter` 绘制逐字填充。
- 使用 `TextPainter` 缓存文本布局。
- position 变化时只重绘颜色区域。

## 10.5 列表优化

- 长列表统一使用 `ListView.builder` 或 `SliverList`。
- 搜索分组模式使用 `CustomScrollView`。
- 列表项不在 `build` 中发网络请求。
- 列表项不重复解码 JSON。
- `ValueKey` 不依赖会变化的 index。
- 仅对可见区域加载较大封面。

## 10.6 搜索优化

涉及：

- `lib/features/search/search_page.dart`
- `lib/features/search/search_results_page.dart`

每个渠道维护独立状态：

```text
idle
loading
success
error
loadingMore
exhausted
```

搜索流程：

```text
创建 SearchSession
→ 并行请求渠道
→ 先返回先展示
→ 渠道失败独立重试
→ 滚动到底加载对应渠道
→ 新搜索取消旧会话
```

QQ 音乐封面补全需要增加 3～4 路并发限制，优先寻找批量详情接口。

## 10.7 动画和模糊

- 每个页面最多一个实时 `BackdropFilter`。
- 播放器背景采用低分辨率图或静态模糊图。
- 列表页面关闭实时模糊。
- 低端设备默认关闭玻璃效果。
- 尊重 `disableAnimations`。
- 页面销毁时取消 Timer、动画、网络订阅。

## 10.8 出口标准

- 中端 Android 设备列表滚动保持 60fps。
- 普通页面单帧耗时小于 16.67ms。
- 1000 条搜索结果不会一次性构建全部 Widget。
- 暂停播放后不再持续运行位置 Timer。
- 搜索首个结果不等待最慢渠道。

---

# 11. 迭代阶段 I4：渠道和内容完整度

## 11.1 YTM 歌词

实施顺序：

1. 获取 captions/timedtext 数据。
2. 解析为统一 `LyricBundle`。
3. 先支持逐行 LRC 兼容格式。
4. 再根据字幕时间粒度增加逐字能力。
5. 失败时明确显示“暂无可用歌词”。

不应在未验证接口前宣称完整逐字歌词能力。

## 11.2 QQ 账号歌单

实施顺序：

1. 验证登录态下歌单接口。
2. 建立脱敏响应 Fixture。
3. 实现 `RemotePlaylistCapable`。
4. 增加分页和失败重试。
5. 对会员、隐私歌单和空歌单分别处理。

## 11.3 WebDAV 同步

同步范围：

- 收藏。
- 历史。
- 自建歌单。
- 非敏感设置。

禁止同步：

- Cookie。
- Token。
- 密码。
- WebView 会话。
- 临时播放 URL。

冲突策略：

```text
记录更新时间
→ 相同 Key 去重
→ 收藏取并集
→ 历史按时间合并后裁剪
→ 歌单按名称合并并按 Track Key 去重
→ 设置按字段时间戳取新值
```

## 11.4 诊断能力

增加：

- 环形日志。
- 渠道请求成功率统计。
- 播放解析耗时。
- 点歌到出声耗时。
- 本地扫描耗时。
- 缓存占用统计。
- 脱敏诊断包导出。

---

# 12. Bug 整改总表

| ID | Bug/风险 | 处理阶段 | 验收方式 |
|---|---|---|---|
| B01 | Release 使用 Debug 签名 | I0/I1 | Release 构建和签名验证 |
| B02 | 核心文件未提交或未跟踪 | I0 | 干净 clone 构建 |
| B03 | 系统媒体队列索引过期 | I1 | 车机/通知栏队列测试 |
| B04 | 完整播放 URL 进入日志 | I1 | 日志敏感信息扫描 |
| B05 | WebView 收集全部站点 Cookie | I1 | Cookie 域名白名单测试 |
| B06 | 酷狗 HTTP 播放地址和凭据传递不安全 | I1 | 平台播放和抓包验证 |
| B07 | YTM 会话校验恒为成功 | I1 | 有效/失效/断网测试 |
| B08 | Hive Box 损坏导致启动失败 | I1 | 损坏数据启动测试 |
| B09 | MQTT 坏包导致扫码终止 | I1/I4 | 坏包和重连测试 |
| B10 | 播放器状态机没有测试 | I1 | PlayerNotifier 测试套件 |
| B11 | PlayerPage 10Hz 全量重建 | I3 | Profile Timeline 验证 |
| B12 | 歌词整体随进度刷新 | I3 | Widget 重建和帧耗时验证 |
| B13 | 本地扫描运行在 UI isolate | I2 | 1000 首曲库扫描测试 |
| B14 | ID3 大标签读取截断 | I2 | 大封面 Fixture 测试 |
| B15 | 历史每次全表排序 | I2 | 性能和写入次数测试 |
| B16 | 歌单批量保存 O(n²) | I2 | 500 首批量写入测试 |
| B17 | 备份导入非原子 | I2 | 中途异常回滚测试 |
| B18 | 分组搜索使用非懒加载列表 | I3 | 1000 条结果滚动测试 |
| B19 | 搜索首屏等待所有渠道 | I3 | 慢渠道模拟测试 |
| B20 | 分页失败被判定为到底 | I3 | 重试按钮 Widget 测试 |
| B21 | 位置 Timer 空闲时持续唤醒 | I3 | 暂停状态 Timer 验证 |
| B22 | Provider family 长期累积 | I2/I3 | 长时间切歌内存测试 |
| B23 | UTF-16 代理对解析异常 | I2 | Emoji 标签测试 |
| B24 | LRC 超长文本判重 O(n²) | I2 | 超长歌词性能测试 |
| B25 | resume 空队列 clamp 隐患 | I1 | 空快照和越界测试 |
| B26 | 依赖补丁依赖本机 pub cache | I0/I1 | 干净 Linux/macOS 构建 |
| B27 | 错误只有 debugPrint 无诊断 | I4 | 脱敏日志导出测试 |
| B28 | 账号启动校验同时打满网络 | I1 | 错峰校验和限流测试 |

---

# 13. 测试计划

## 13.1 单元测试

必须覆盖：

- `Track` 序列化和迁移。
- `QueueLogic` 全部播放模式。
- `PlayerNotifier` 状态转换。
- `AudioHandler` 队列索引和系统操作。
- `ResumeRepository` 损坏和边界快照。
- `AccountRepository` Blob、迁移、并发和清理。
- `SourceAuthInterceptor` 认证注入和过期判定。
- `NetworkConfig` 超时策略。
- LRC、YRC、TTML 和异常时间轴。
- ID3 大标签、编码和代理对。
- MQTT 长度、坏包、QoS 和重连。
- BackupService 校验、导入和回滚。

## 13.2 渠道协议测试

每个渠道至少保存一套脱敏 Fixture：

```text
搜索成功
搜索空结果
播放地址成功
播放地址无权限
登录成功
登录失败
会话过期
网络异常
响应格式变化
```

禁止把真实 Cookie、Token、手机号或用户信息提交到 Fixture。

## 13.3 Widget 测试

增加：

- PlayerPage 播放/暂停状态。
- PlayerPage 队列管理。
- MiniPlayer 状态。
- 搜索先到先显示。
- 搜索渠道失败重试。
- 账号过期引导。
- 设置缓存清理。
- 备份导入失败提示。
- 亮色和深色主题关键页面。

## 13.4 集成测试

主链路：

```text
启动
→ 搜索
→ 打开结果
→ 播放
→ 暂停/恢复
→ 切歌
→ 查看歌词
→ 收藏
→ 添加歌单
→ 重启恢复
```

平台链路：

- Android 通知、锁屏、耳机按键。
- iOS 音频打断和后台播放。
- macOS Keychain 和最小窗口。
- Windows SMTC、窗口和 WebView 登录。

## 13.5 覆盖率策略

覆盖率不以测试代码行数为唯一目标，优先关注：

- 分支覆盖。
- 异常分支。
- 并发和取消路径。
- 数据迁移路径。
- 安全过滤路径。
- 平台差异路径。

建议门槛：

| 模块 | 初始目标 |
|---|---:|
| core/domain | 85% |
| player/application | 80% |
| repository/data | 80% |
| source parser | 85% |
| UI | 60% |
| 全项目 | 70% 起步 |

---

# 14. 发布计划

## 14.1 Alpha

条件：

- I0 完成。
- 核心播放链路可用。
- Android 和一个桌面平台通过基础回归。

发布内容：

- 仅个人或小范围测试。
- 明确列出渠道不稳定风险。
- 不承诺所有渠道长期可用。

## 14.2 Beta

条件：

- I1～I3 完成。
- CI 稳定运行。
- Release 签名完成。
- 核心测试和集成测试通过。
- 性能指标达到目标的 80% 以上。

发布包：

- Android APK。
- Windows 压缩包。
- macOS 安装包。
- iOS 仅按实际签名和分发能力发布。

## 14.3 V1.0

条件：

- 所有 P0 Bug 关闭。
- Android、iOS、macOS、Windows 完成核心回归。
- 无已知高风险安全问题。
- 启动、播放、内存、缓存达到出口标准。
- README、渠道矩阵、隐私说明和安装说明同步。

---

# 15. 性能和质量指标

## 15.1 启动

- 冷启动首帧：小于 1 秒。
- 首页可交互：小于 1.5 秒。
- 启动阶段不弹出阻塞式权限窗口。

## 15.2 播放

- 点歌到出声 p50：小于 800ms，Wi-Fi 环境。
- 快速连续点歌不会旧请求覆盖新请求。
- 当前歌曲、系统媒体和队列索引始终一致。

## 15.3 内存

- 普通播放常驻内存目标小于 150 MB。
- 播放 30 分钟无持续线性增长。
- 连续切换 100 首后旧资源可以释放。
- 本地扫描期间无整库原始字节驻留。

## 15.4 流畅度

- 中端 Android 列表滚动保持 60fps。
- 普通页面单帧耗时小于 16.67ms。
- 1000 条结果不一次性构建全部 Widget。
- 本地扫描时 UI 保持可操作。

## 15.5 存储

- 网络封面缓存不超过 100 MB。
- 本地封面缓存不超过 256 MB。
- 诊断日志不超过 5 MB。
- 历史最多 200 条。
- 备份导入失败不改变原始数据。

## 15.6 安全

- 日志不得包含 Cookie、Token、Authorization、密码和完整播放 URL。
- 凭据只进入系统安全存储。
- 备份和 WebDAV 不同步凭据。
- WebView Cookie 必须通过域名和字段白名单。
- Release 构建不得使用 Debug 签名。

---

# 16. Git、提交和协作规范

## 16.1 提交粒度

建议按以下顺序提交：

```text
chore: establish clean project baseline
ci: restore analysis and test workflow
fix(security): sanitize logs and restrict web cookies
fix(player): synchronize system queue index
fix(auth): make credential storage atomic
perf(storage): optimize history and playlist writes
perf(local): move library scan off UI isolate
perf(ui): reduce player and lyrics rebuilds
feat(search): stream per-source results and retry failures
chore(release): add release signing configuration
```

## 16.2 禁止事项

- 不提交真实凭据。
- 不提交 keystore。
- 不直接修改本机 pub cache 作为构建步骤。
- 不在一个提交中混合重构、功能和大规模资源变化。
- 不在未验证平台构建前删除旧平台入口。
- 不使用 root/sudo 生成项目文件。

## 16.3 文件权限

项目目录标准属主：

```text
tenonsuzu:staff
```

后续应直接使用当前用户执行 DSH、Flutter 和 Git。若误用 sudo 生成文件，应及时恢复：

```bash
sudo chown -R tenonsuzu:staff /Users/tenonsuzu/Documents/Codes/Musaic
sudo chmod -R u+rwX /Users/tenonsuzu/Documents/Codes/Musaic
```

---

# 17. 风险管理

| 风险 | 概率 | 影响 | 应对方案 |
|---|---|---|---|
| 渠道接口变动 | 高 | 高 | 渠道隔离、Fixture、快速 hotfix |
| 音乐版权或接口合规 | 中 | 高 | 只调用允许的公开能力，保持免责声明 |
| WebView Cookie 变化 | 高 | 中 | 白名单、可替换 Cookie 提取层 |
| Android/AGP 版本变化 | 中 | 高 | 固定版本、CI 干净构建 |
| 本地大曲库卡顿 | 高 | 高 | isolate、增量索引、并发上限 |
| 播放状态竞态 | 中 | 高 | 命令串行化、状态机测试 |
| Hive 数据损坏 | 低 | 高 | 备份、重建、迁移和恢复提示 |
| macOS Keychain 配置问题 | 中 | 高 | 真机优先验证 entitlement |
| 单人开发范围失控 | 高 | 中 | 里程碑冻结、严格区分 P0/P1/P2 |
| 高级功能平台不一致 | 中 | 中 | 平台能力检测和功能开关 |

---

# 18. 推荐执行时间表

## 第 1 周：基线和安全

- 整理未提交文件。
- 恢复 CI。
- 修复 Release 签名。
- 移除敏感日志。
- 修复 Cookie 白名单。
- 修复 YTM 会话判断。
- 建立 PlayerNotifier 测试骨架。

## 第 2 周：播放和启动

- 修复系统队列索引。
- 增加播放操作串行化。
- 增加 AudioHandler 测试。
- Hive 启动容错。
- 延迟权限和 AudioService 初始化。
- 增加播放主链路集成测试。

## 第 3 周：存储和本地库

- 凭据 Blob 和迁移。
- 历史索引优化。
- 歌单批量写入和互斥。
- 备份导入回滚。
- 封面缓存上限和清理。
- ID3 动态长度读取。

## 第 4 周：内存和扫描

- 本地扫描 isolate 化。
- 增量扫描索引。
- 图片缓存限制。
- Provider 生命周期治理。
- 本地扫描性能测试。

## 第 5 周：搜索和 UI 流畅度

- 搜索流式返回。
- 渠道失败重试。
- Sliver 长列表。
- PlayerPage 精确 `select`。
- 歌词当前行局部重绘。
- 取消空闲位置 Timer。

## 第 6 周：渠道回归和 Beta 准备

- 网易云、QQ、酷狗、YTM Fixture。
- Android、iOS、macOS、Windows 核心回归。
- 诊断日志导出。
- 性能报告。
- Beta 构建和发布说明。

## 第 7～8 周：内容完整度

- YTM 字幕歌词。
- QQ 账号歌单。
- 资料库导入导出增强。
- 用户反馈问题修复。
- 版本冻结。

---

# 19. 里程碑 Definition of Done

一个迭代只有同时满足以下条件才算完成：

1. 功能代码已经实现。
2. 相关异常和边界条件已经处理。
3. 新增核心逻辑有单元测试。
4. UI 行为有必要的 Widget 测试。
5. `dart format` 通过。
6. `flutter analyze` 通过。
7. `flutter test` 通过。
8. 至少一个移动平台和一个桌面平台完成验证。
9. 性能变化有前后对比数据。
10. 没有新增敏感日志或明文凭据。
11. README、渠道能力矩阵和迭代计划同步。
12. Git 提交可以独立回滚。

---

# 20. 最终执行优先级

## 必须先做

```text
工作树基线
→ CI
→ Release 签名
→ 日志/Cookie/凭据安全
→ 播放队列索引
→ 播放器状态机测试
```

## 第二批做

```text
Hive 容错
→ 历史和歌单存储优化
→ 备份回滚
→ 本地扫描 isolate
→ 图片缓存限制
→ Provider 生命周期
```

## 第三批做

```text
PlayerPage 重建优化
→ 歌词局部重绘
→ 搜索流式结果
→ Sliver 长列表
→ 空闲 Timer 取消
→ 性能基线自动化
```

## 最后再做

```text
YTM 歌词
→ QQ 账号歌单
→ WebDAV
→ 诊断上报
→ 自定义渠道
→ DLNA/Android Auto/均衡器
```

---

## 结语

Musaic 当前已经具备成为稳定跨平台音乐播放器的基础。下一阶段最重要的不是继续增加渠道数量，而是把现有功能变成可发布、可恢复、可测试、可长期运行的软件。

本计划的核心成功标准是：

```text
用户可以稳定搜索和播放
→ 队列和系统媒体行为正确
→ 数据不会因异常丢失
→ 凭据不会泄露
→ 大曲库不会卡顿
→ 长时间播放不会持续涨内存
→ 干净环境可以构建和发布
```

达到这些条件后，再扩展 WebDAV、YTM 歌词和自定义渠道，项目的长期维护成本会显著降低。
