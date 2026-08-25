import '../model/track.dart';

/// 音乐渠道抽象。
///
/// 每个音乐来源（网易云、本地文件等）必须实现该接口。
/// UI 层永不直接依赖具体渠道实现。
abstract class MusicSource {
  /// 渠道唯一标识，如 `"netease"`、`"local"`。
  String get sourceId;

  /// 渠道展示名称，如 `"网易云音乐"`、`"本地文件"`。
  String get sourceName;

  /// 搜索曲目。
  ///
  /// [query] 为搜索关键词。
  /// 返回统一曲目列表。
  Future<List<Track>> search(String query);

  /// 获取曲目详情。
  ///
  /// 可用于补充曲目信息（如封面、歌词、时长）。
  Future<Track> getTrackDetail(Track track);

  /// 获取播放地址。
  ///
  /// 返回可直接用于播放的 URL（如 https:// 或 file://）。
  Future<String> getStreamUrl(Track track);

  /// 获取歌词。
  ///
  /// 返回 LRC/TTML 文本，或 null 表示无歌词。
  Future<String?> getLyrics(Track track);

  /// 登录。
  ///
  /// [credentials] 由渠道 AuthCapability 声明，由 UI 动态生成。
  /// P1 暂不实现，预留接口。
  Future<void> login(Map<String, String> credentials) async {
    throw UnimplementedError('login');
  }

  /// 登出。
  Future<void> logout() async {
    throw UnimplementedError('logout');
  }

  /// 校验当前会话是否有效。
  Future<bool> checkSession() async => true;

  /// 当前登录状态。
  bool get isLoggedIn => false;
}
