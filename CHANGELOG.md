# Changelog

本文件记录 Musaic 的版本变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2026-09-13

首个正式版本。Musaic = Music + Mosaic，汇聚多方音源的多渠道音乐播放器（Flutter）。

### 新增

- **多渠道聚合**：统一搜索（搜索历史、合并/分组展示、目标渠道多选）/ 播放 / 歌词；渠道可插拔，
  UI 零改动接入新渠道。
- **渠道矩阵**：
  - 网易云：搜索 / 播放 / 逐字歌词；手机密码 + 二维码扫码登录，登录后展示昵称与黑胶/VIP 等级，
    支持资料刷新与退出。
  - QQ 音乐：搜索 / 歌词 / 封面；QQ 音乐 App 扫码登录（CreateQRCode + MQTT，tmeLoginType=6），
    登录后展示昵称与绿钻等级，解锁认证 vkey 播放。
  - 酷狗：搜索 / 播放 / 封面；h5 二维码扫码登录（web 签名），token/userid 解锁完整试听。
  - YTM：搜索 / 播放（需可访问 YouTube）；WebView Google 登录（Cookie 提取 + SAPISIDHASH 校验）。
- **本地文件**：扫描本地目录，ID3v2/v1 标签与内嵌封面，同名 `.lrc` 与 USLT 歌词。
- **远端账号歌单**（网易云 / QQ 音乐 / 酷狗）：拉取已登录账号下的歌单并在应用内展示与播放。
  酷狗走公开发现链（无需登录），曲目数经批量详情接口补齐。
- **按渠道账号**：三态状态机（未登录 / 已登录 / 已过期），启动乐观恢复 + 后台校验 + 401 被动捕获。
- **播放内核**：just_audio + audio_service，通知栏 / 锁屏 / SMTC / Now Playing、队列、
  顺序 / 列表循环 / 单曲循环 / 随机、「上一首超 3 秒先回开头」、定时关闭、并发保护、
  交叉淡入、播放地址预取、跨渠道换源（无版权时自动切到其它渠道同曲版本）。
- **沉浸式播放器**：封面取色动态渐变背景、Hero 封面、下滑手势关闭、拖拽加粗进度条；
  横屏右侧区域支持点击在「歌词 / 控件」之间切换。
- **歌词**：官方 YRC > TTML > LRC 三级降级，词级填充高亮、点行跳转、翻译合并。
- **内容页面**：首页（最近播放 / 继续收听 / 快捷入口）、聚合搜索、资料库（本地歌单与账号云端歌单、
  批量多选操作、歌单排序）、歌单详情。
- **设置中心**：账号管理、外观（主题 / OLED 黑 / 玻璃模糊 / 封面取色）、
  播放与性能（网络超时 / 音质 / 蜂窝降质）、本地音乐（扫描文件夹管理）、数据管理（备份导入导出）、关于。
- **状态保持**：重启后恢复上次播放队列、进度、播放模式、随机开关与音量。

### 安全

- 凭据仅存入 Keychain / Keystore / DPAPI，永不明文落盘；支持一键清除所有账号数据。
- 全量日志经统一 `AppLog` 门面脱敏（URL query、Cookie / Authorization 头、Bearer/Basic token
  及 token / unikey / MUSIC_U / musickey / SAPISID 等敏感键），并提供诊断日志导出。
- YTM / YouTube Cookie 采集仅持久化白名单键，不落整份 `accounts.google.com` cookie jar。
- 资料库备份导入采用「先写后剪」回滚，避免导入中断导致空库。

### 工程

- 架构分层由 `test/architecture_test.dart` 守护（core ↛ features/sources、features ↛ sources、
  sources ↛ features，组合根 `lib/core/di` 豁免）。
- 版本号单一来源 `lib/core/app_info.dart`，与 `pubspec.yaml` 由测试断言一致。
- CI（`.github/workflows/ci.yml`）：格式检查、静态分析零警告、单元 + Widget 测试（含分层覆盖率门槛）、
  Android debug APK 构建冒烟；触发条件为主分支 push 与针对主分支的 PR。
- 覆盖率门槛按层设定（core 80% / features 60% / sources 30% / 全项目 55%），由零依赖脚本
  `tool/check_coverage.py` 解析 `lcov.info` 校验。

### 说明

- 仅网易云提供**词级**（逐字）时间轴；QQ 音乐 / 酷狗 / YTM / 本地文件为**逐行**。
- 歌单按渠道相关键去重，同一首歌的多个渠道版本**刻意共存**（音质 / 版权 / 会员各渠道不同）。
- 本项目仅用于学习研究，只调用各渠道公开接口，不破解、不缓存受限内容，请支持正版音乐服务。

[1.0.0]: https://github.com/YoisakiKnd/Musaic/releases/tag/v1.0.0
