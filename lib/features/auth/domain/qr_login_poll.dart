/// 二维码登录轮询状态（跨渠道共享领域模型）。
///
/// 网易云（unikey）与 QQ（ptlogin qrsig）等扫码流程共用同一状态机：
/// waiting → scanned → success，或 expired 后重新创建。
library;

sealed class QrLoginPoll {
  const QrLoginPoll();

  factory QrLoginPoll.waiting() = QrLoginPollWaiting;
  factory QrLoginPoll.scanned() = QrLoginPollScanned;
  factory QrLoginPoll.expired() = QrLoginPollExpired;
  factory QrLoginPoll.success({
    required Map<String, String> credentials,
    String? nickname,
  }) = QrLoginPollSuccess;
}

class QrLoginPollWaiting extends QrLoginPoll {
  const QrLoginPollWaiting();
}

class QrLoginPollScanned extends QrLoginPoll {
  const QrLoginPollScanned();
}

class QrLoginPollExpired extends QrLoginPoll {
  const QrLoginPollExpired();
}

class QrLoginPollSuccess extends QrLoginPoll {
  const QrLoginPollSuccess({required this.credentials, this.nickname});

  /// 登录成功产出的凭据（键值由各渠道定义，如 MUSIC_U / musickey）。
  final Map<String, String> credentials;

  final String? nickname;
}
