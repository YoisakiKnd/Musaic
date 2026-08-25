# Musaic — 音乐拼图

> **Musaic** = Music + Mosaic —— 汇聚多方音源的音乐拼图。
> 多渠道聚合 · 按渠道独立账号 · 逐字歌词 · 沉浸式播放体验（Flutter）

架构灵感：[PicaComic](https://github.com/wgh136/PicaComic)（多源插件化、按源独立账号）
体验灵感：Mei（Apple Music 风格、逐字歌词、流体玻璃）

---

## 功能总览（V1）

| 能力 | 说明 |
|---|---|
| 多渠道聚合 | 统一搜索 / 播放 / 歌词；渠道可插拔，UI 零改动接入新渠道 |
| 网易云音乐 | 匿名搜索/播放/逐字歌词；MUSIC_U Cookie 登录（含图文指引） |
| 本地文件 | 扫描本地目录，ID3v2/v1 标签与内嵌封面，同名 .lrc 与 USLT 歌词 |
| 按渠道账号 | 三态状态机（未登录/已登录/已过期），启动乐观恢复 + 后台校验 + 401 被动捕获 |
| 播放内核 | just_audio + audio_service：通知栏/锁屏/SMTC/Now Playing、队列、顺序/循环/单曲/随机、「上一首超 3 秒先回开头」、定时关闭 |
| 沉浸式播放器 | 封面取色动态渐变背景、Hero 封面、下滑手势关闭、拖拽加粗进度条 |
| 逐字歌词 | 官方 YRC > TTML > LRC 三级降级，词级填充高亮、点行跳转、翻译合并 |
| 内容页面 | 首页（最近播放）、聚合搜索（按渠道分组）、资料库（喜欢/历史/自建歌单） |
| 安全 | 凭据仅入 Keychain/Keystore/DPAPI，永不明文落盘；日志脱敏；一键清除所有账号数据 |

## 快速开始

```bash
flutter pub get
flutter run            # 默认设备
flutter test           # 单元 + Widget 测试
flutter analyze        # 静态检查（当前零警告基线）
```

平台支持：Android / iOS / macOS / Windows。

> macOS 首次运行需在 Xcode 中确认 Runner 已启用 App Sandbox 并包含
> `keychain-access-groups` entitlement（仓库内已配置），否则安全存储不可用。

## 架构速览

```
lib/
├── app/                  # AppShell 自适应骨架 + go_router 路由表
├── core/
│   ├── theme/            # AppTokens 设计令牌（深色优先）
│   ├── model/            # Track 统一曲目模型
│   ├── source/           # MusicSource 抽象 + SourceRegistry 注册中心
│   ├── network/          # SourceAuthInterceptor（凭据注入/过期捕获）
│   ├── error/            # SourceException 异常族
│   └── di/               # 组合根 Provider（override 注入）
├── features/
│   ├── auth/             # 账号系统（domain/data/application/presentation）
│   ├── player/           # PlayerNotifier + AudioHandler + MiniPlayer/PlayerPage
│   ├── lyrics/           # LyricBundle + TTML/YRC/LRC 解析器 + LyricsView
│   ├── library/          # 喜欢/历史/歌单（Hive 本地优先）
│   ├── theme/            # 封面取色动态配色
│   └── shared/widgets/   # TrackTile 等复用组件
└── sources/
    ├── netease/          # 网易云渠道实现
    └── local/            # 本地文件渠道（含 ID3 解析器）
```

模块依赖铁律（Master Plan §3.2）：

1. 表现层只依赖应用层；
2. **UI 永不直接 import 渠道实现**——一切经 `SourceRegistry` 解析；
3. 渠道实现只依赖领域层；
4. 凭据只能经 `AccountRepository` 进出安全存储。

## 新增一个渠道 = 三步

1. 新建 `lib/sources/<id>/xxx_source.dart` 实现 `MusicSource`；
2. 通过 `AuthCapability` 声明登录方式与表单字段（动态登录弹窗自动适配）；
3. 在 `lib/core/di/app_providers.dart` 的 `sourceRegistryProvider` 中注册一行。

## 与 Master Plan 的实现差异说明

计划书第 12 节约定「版本以 `flutter pub get` 实际解析为准」，据此做了如下替换：

| 计划书依赖 | 实际采用 | 原因 |
|---|---|---|
| `palette_generator_master` | `palette_generator`（官方） | 原包在 pub.dev 无法解析 |
| `flutter_lyric` | 自研 `LyricsView` | 包版本不可解析；自研渲染对词级填充与点击跳转控制更精确 |
| `liquid_glass_container_plus` | 自研受控 `BackdropFilter`（MiniPlayer 处唯一实时模糊区，外包 RepaintBoundary） | 性能预算 §10.2 更可控 |
| `golden_toolkit` | 未引入 | 项目已停止维护，与新 Flutter 版本存在约束冲突 |

## 测试策略（Master Plan §15）

- **单元**：Track 序列化、队列逻辑（模式/洗牌/回开头规则）、TTML/YRC/LRC 解析、ID3 解析、凭据存储命名空间隔离与输入清洗
- **Widget**：登录弹窗动态表单渲染、失败提示、成功关闭路径

```bash
flutter test   # 67 tests passing
```

## 路线图状态

- [x] P0 地基（令牌/模型/CI 基线）
- [x] P1 播放核心（本地渠道 + MiniPlayer + 骨架）
- [x] P2 多渠道骨架（抽象/注册中心/网易云匿名能力）
- [x] P3 账号系统（声明式登录/安全存储/生命周期）
- [x] P4 沉浸式播放器
- [x] P5 逐字歌词
- [x] P6 内容页面
- [x] P7 打磨（平台配置/测试/文档）
- [ ] V1.1+ 扫码登录、WebDAV 同步、自定义渠道（见 musaic-master-plan.md §18）

## 免责声明

本项目仅作为学习研究用途，只调用各音乐渠道官方公开接口，不破解、不缓存受限内容。请支持正版音乐服务。
