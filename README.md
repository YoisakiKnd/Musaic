# Musaic

**Musaic** = Music + Mosaic —— 汇聚多方音源的音乐拼图

多渠道音乐播放器（Flutter）· 跨平台 · 开源

> 架构灵感：PicaComic（多源插件化、按源独立账号）
> 体验灵感：Mei（Apple Music 风格、逐字歌词、流体玻璃）

---

## 核心特性

- 多渠道聚合：统一搜索/播放/收藏网易云音乐、本地文件，渠道可插拔
- 按渠道账号：每个渠道独立登录、独立凭据、独立状态
- 沉浸式体验：逐字歌词、封面取色动态背景、流体玻璃效果
- 跨平台：Android / iOS / macOS / Windows 一套代码
- 低内存：播放中常驻内存目标 < 150MB

---

## 快速开始

### 环境要求

- Flutter SDK >= 3.22.0
- Dart SDK >= 3.3.0

### 安装依赖

```bash
flutter pub get
```

### 运行

```bash
# Android
flutter run -d android

# macOS
flutter run -d macos

# Windows
flutter run -d windows

# iOS
flutter run -d ios
```

### 构建

```bash
# Android APK
flutter build apk --release

# macOS
flutter build macos --release

# Windows
flutter build windows --release
```

---

## 项目结构

```
lib/
├── app/
│   ├── app_shell.dart               # 自适应骨架（导航 + MiniPlayer 悬浮层）
│   └── router.dart                  # go_router 路由表
├── core/
│   ├── theme/app_tokens.dart        # 设计令牌
│   ├── model/track.dart             # 统一曲目模型
│   ├── source/                      # MusicSource 抽象 + SourceRegistry
│   └── network/                     # SourceAuthInterceptor
├── features/
│   ├── auth/                        # 账号系统
│   ├── player/                      # 播放（PlayerNotifier + MiniPlayer/PlayerPage/widgets）
│   ├── lyrics/                      # 歌词（LyricBundle/TTML 解析/Provider）
│   ├── theme/                       # 动态取色
│   ├── home/                        # 首页：推荐 + 最近播放
│   ├── search/                      # 多渠道聚合搜索
│   └── library/                     # 歌单/喜欢/历史
└── sources/
    ├── netease/                     # 网易云渠道
    └── local/                       # 本地文件渠道
```

---

## 开发路线

| 阶段 | 内容 | 状态 |
|------|------|------|
| P0 | 地基（工程初始化、设计令牌、核心模型） | ✅ |
| P1 | 播放核心（PlayerNotifier、本地文件、MiniPlayer） | ✅ |
| P2 | 多渠道骨架（MusicSource 抽象、网易云搜索） | ✅ |
| P3 | 账号系统（领域层、存储层、登录弹窗） | ✅ |
| P4 | 沉浸式播放器（PlayerPage、封面取色、Hero） | ✅ |
| P5 | 逐字歌词（TTML 解析、LyricsView） | ✅ |
| P6 | 内容页面（首页、搜索、资料库） | ✅ |
| P7 | 打磨与发布（性能、测试、文档） | 🚧 |

---

## 技术栈

- **状态管理**：flutter_riverpod
- **路由**：go_router
- **网络**：dio
- **存储**：flutter_secure_storage + hive
- **播放**：just_audio + audio_service
- **UI**：Material 3 + palette_generator_master

---

## 免责声明

本软件仅供学习交流使用，请勿用于商业用途。
使用本软件产生的任何版权问题由使用者自行承担。

---

## 许可证

MIT
