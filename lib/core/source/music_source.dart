import '../../features/auth/domain/auth_capability.dart';
import '../../features/auth/domain/auth_result.dart';
import '../../features/lyrics/domain/lyric_bundle.dart';
import '../model/track.dart';

/// 解析出的播放流（Master Plan §7：每次播放实时解析，不缓存过期 URL）。
class ResolvedStream {
  const ResolvedStream({
    required this.url,
    this.headers,
    this.isLocalFile = false,
  });

  /// 可直接交给播放器的地址：`https://`、`file://` 或本地绝对路径。
  final String url;

  /// 播放该地址需要的请求头（如防盗链 Referer / Cookie）。
  final Map<String, String>? headers;

  final bool isLocalFile;
}

/// 凭据读取器：返回某渠道当前存储的全部凭据字段（无登录时为空 Map）。
typedef CredentialReader = Future<Map<String, String>> Function();

/// 音乐渠道抽象（账号文档 §5.1 + Master Plan §5）。
///
/// - UI 层永不直接依赖具体渠道实现，一切经 [SourceRegistry] 解析。
/// - 渠道实现只依赖领域层，不依赖 UI。
/// - [credentialReader] 由组合根注入（读自安全存储），渠道自身不接触存储细节。
abstract class MusicSource {
  MusicSource({required this.credentialReader});

  final CredentialReader credentialReader;

  /// 渠道唯一标识，如 `"netease"`、`"local"`。
  String get sourceId;

  /// 渠道展示名称。
  String get displayName;

  /// 登录能力声明，驱动动态登录表单与账号中心徽章。
  AuthCapability get authCapability;

  /// 搜索曲目；[offset] 支持分页加载。
  Future<List<Track>> search(String query, {int limit = 30, int offset = 0});

  /// 补全曲目详情（封面 / 时长等）。
  Future<Track> getTrackDetail(Track track);

  /// 实时解析播放地址。
  Future<ResolvedStream> resolveStream(Track track);

  /// 获取歌词；渠道内部完成「官方逐字 > TTML > LRC」降级，无歌词返回 null。
  Future<LyricBundle?> fetchLyrics(Track track);

  /// 用声明的凭据尝试登录并验证；成功返回带资料的 [AuthSuccess]。
  Future<AuthResult> login(Map<String, String> credentials) async {
    return const AuthFailure(
      reason: AuthFailureReason.unsupported,
      message: '该渠道不支持程序化登录',
    );
  }

  /// 登出（渠道侧清理；本地凭据删除由 AccountRepository 负责）。
  Future<void> logout() async {}

  /// 校验已存凭据是否仍然有效（供启动时后台校验）。
  Future<bool> checkSession() async => false;
}
