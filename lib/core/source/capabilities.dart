/// 渠道可选能力声明（Master Plan §3.2 模块规则 2 的落地机制）。
///
/// UI 层需要渠道的「音乐能力之外」的行为（扫码登录 / 账号歌单 / 本地扫描…）
/// 时，一律经本文件的抽象接口访问：
/// `registry.resolve(id)` 后以 `source is QrLoginCapable` 判定能力，
/// **永不 import `lib/sources/` 下的具体实现**。
/// 渠道实现通过 `implements` 相应接口接入，注册中心零改动。
library;

import 'dart:typed_data';

import '../auth/auth_capability.dart';
import '../auth/auth_result.dart';
import '../auth/qr_login_poll.dart';
import '../model/remote_playlist.dart';
import '../model/track.dart';

// ---------- 扫码登录 ----------

/// 一次扫码会话：轮询键 + 二维码的两种呈现形态（渠道提供 PNG，
/// 或提供待本地渲染的内容 URL，二选一，PNG 优先展示）。
class QrLoginSession {
  const QrLoginSession({
    required this.pollKey,
    this.png,
    this.contentUrl,
  });

  /// 轮询状态所需的会话标识（网易云 unikey / QQ qrsig / 微信 uuid / 酷狗 qrcode）。
  final String pollKey;

  /// 渠道服务端生成的二维码图片字节。
  final Uint8List? png;

  /// 需客户端本地渲染成二维码的跳转内容（如网易云登录 URL）。
  final String? contentUrl;

  bool get hasPng => png != null && png!.isNotEmpty;
}

/// 单条扫码登录流水线（渠道内以闭包封装自己的 create/poll 接口）。
class QrLoginFlow {
  const QrLoginFlow({
    required this.id,
    required this.label,
    required this.scanHint,
    required this.create,
    required this.poll,
    this.interval = const Duration(seconds: 2),
    this.userIdCredentialKey,
    this.fallbackNickname = '用户',
    this.footerHint,
  });

  /// 流水线标识（同一渠道多通道时区分，如 `qq` / `wechat`）。
  final String id;

  /// Tab 标签（如「QQ 扫码」）。
  final String label;

  /// 二维码生成后的引导文案（如「请使用手机 QQ 扫一扫」）。
  final String scanHint;

  /// 轮询间隔。
  final Duration interval;

  /// 成功凭据中作为账号 userId 的键（如 uin / userid）；无则 null。
  final String? userIdCredentialKey;

  /// 拉不到昵称时的兜底展示名。
  final String fallbackNickname;

  /// 页面底部辅助说明。
  final String? footerHint;

  final Future<QrLoginSession> Function() create;
  final Future<QrLoginPoll> Function(QrLoginSession session) poll;
}

/// 具备扫码登录能力的渠道（网易云 / QQ / 酷狗…）。
abstract class QrLoginCapable {
  /// 至少一条扫码流水线；多渠道通道（QQ/微信）返回多条。
  List<QrLoginFlow> get qrLoginFlows;
}

// ---------- 账号密码登录 ----------

/// 具备账号密码登录能力的渠道（如网易云手机号 + 密码）。
abstract class PasswordLoginCapable {
  /// Tab 标签（如「手机号登录」）。
  String get passwordTabLabel;

  /// 表单字段声明（驱动通用表单渲染）。
  List<CredentialField> get passwordFields;

  /// 提交按钮下方的安全说明。
  String get passwordSubmitHint;

  /// 以表单值登录；成功返回 [AuthSuccess.credentials] 供落安全存储。
  Future<AuthResult> loginWithPassword(Map<String, String> values);
}

// ---------- WebView Cookie 登录 ----------

/// 具备 WebView 登录能力的渠道（如 YTM 的 Google 登录）：
/// UI 内嵌浏览器打开 [webLoginUrl]，用户完成后提取站点 Cookie，
/// 交给 [loginWithWebCookies] 校验并换取账号资料。
abstract class WebLoginCapable {
  Uri get webLoginUrl;

  /// AppBar 操作按钮文案（如「我已登录」）。
  String get webLoginActionLabel => '我已登录';

  /// 底部提示文案。
  String get webLoginHint =>
      '在上方页面完成登录后点击按钮；凭据仅保存在本机安全存储。';

  Future<AuthResult> loginWithWebCookies(Map<String, String> cookies);
}

// ---------- 远端账号歌单 ----------

/// 具备「登录后拉取账号歌单」能力的渠道。
abstract class RemotePlaylistCapable {
  /// 当前登录账号（[userId] 来自 [SourceAccount]）的歌单列表。
  Future<List<RemotePlaylist>> fetchRemotePlaylists(String userId);

  /// 歌单详情 → 统一曲目列表。
  Future<List<Track>> fetchRemotePlaylistTracks(String playlistId);
}

// ---------- 本地曲库扫描 ----------

/// 具备本地曲库扫描能力的渠道（本地文件渠道）。
abstract class LibraryScanCapable {
  /// 扫描（结果可缓存；[force] 强制重扫）。
  Future<List<Track>> scanLibrary({bool force = false});

  /// 使缓存的扫描结果失效。
  void invalidateScanCache();
}
