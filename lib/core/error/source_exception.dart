/// 渠道层统一异常（Master Plan §5）。
///
/// 渠道实现抛出该族异常，UI 层据此展示友好信息；禁止把底层堆栈直接抛给界面。
library;

sealed class SourceException implements Exception {
  SourceException(this.message, {this.sourceId});

  final String message;
  final String? sourceId;

  @override
  String toString() =>
      'SourceException($sourceId, $message)'; // 永不包含凭据内容
}

/// 网络不可达 / 超时 / 服务端错误。
class NetworkSourceException extends SourceException {
  NetworkSourceException(super.message, {super.sourceId});
}

/// 曲目无法播放：需要会员、无版权、地区限制等。
class UnavailableStreamException extends SourceException {
  UnavailableStreamException(
    super.message, {
    super.sourceId,
  });
}

/// 需要登录或凭据已失效。
class AuthRequiredException extends SourceException {
  AuthRequiredException(super.message, {super.sourceId});
}
