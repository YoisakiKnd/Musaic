import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/network/response_decoder.dart';
import 'package:musaic/core/network/source_auth_interceptor.dart';

/// 会话过期被动捕获回归（P1）。
///
/// 旧实现要求 `response.data is Map`，但四个渠道全部使用
/// `ResponseType.plain`，`data` 恒为 String → 业务码过期检测
/// **完全失效**，401 被动捕获形同虚设。
void main() {
  RequestOptions options() => RequestOptions(path: '/test');

  Response<dynamic> response(Object? data, {int status = 200}) =>
      Response<dynamic>(
        requestOptions: options(),
        statusCode: status,
        data: data,
      );

  test('JSON 字符串体中的过期业务码被识别（plain 响应）', () {
    var expired = 0;
    final interceptor = SourceAuthInterceptor(
      sourceId: 'test',
      readCredentials: () async => const <String, String>{},
      onSessionExpired: () => expired++,
      expiredBodyCodes: const <int>{301},
    );

    interceptor.onResponse(
      response(jsonEncode(<String, dynamic>{'code': 301, 'msg': 'need login'})),
      ResponseInterceptorHandler(),
    );

    expect(expired, 1, reason: 'String 体必须被 jsonDecode 后再判业务码');
  });

  test('已解析的 Map 体同样被识别', () {
    var expired = 0;
    final interceptor = SourceAuthInterceptor(
      sourceId: 'test',
      readCredentials: () async => const <String, String>{},
      onSessionExpired: () => expired++,
      expiredBodyCodes: const <int>{301},
    );

    interceptor.onResponse(
      response(<String, dynamic>{'code': 301}),
      ResponseInterceptorHandler(),
    );

    expect(expired, 1);
  });

  test('字符串型业务码也被识别', () {
    var expired = 0;
    final interceptor = SourceAuthInterceptor(
      sourceId: 'test',
      readCredentials: () async => const <String, String>{},
      onSessionExpired: () => expired++,
      expiredBodyCodes: const <int>{301},
    );

    interceptor.onResponse(
      response(jsonEncode(<String, dynamic>{'code': '301'})),
      ResponseInterceptorHandler(),
    );

    expect(expired, 1);
  });

  test('非过期业务码不触发', () {
    var expired = 0;
    final interceptor = SourceAuthInterceptor(
      sourceId: 'test',
      readCredentials: () async => const <String, String>{},
      onSessionExpired: () => expired++,
      expiredBodyCodes: const <int>{301},
    );

    interceptor.onResponse(
      response(jsonEncode(<String, dynamic>{'code': 200})),
      ResponseInterceptorHandler(),
    );

    expect(expired, 0);
  });

  test('非法/非 JSON 体不抛异常且不误判', () {
    var expired = 0;
    final interceptor = SourceAuthInterceptor(
      sourceId: 'test',
      readCredentials: () async => const <String, String>{},
      onSessionExpired: () => expired++,
      expiredBodyCodes: const <int>{301},
    );

    for (final body in <Object?>[
      '<html>502 Bad Gateway</html>',
      '{ not json',
      '',
      null,
      42,
    ]) {
      expect(
        () => interceptor.onResponse(
          response(body),
          ResponseInterceptorHandler(),
        ),
        returnsNormally,
        reason: '体为 $body 时不应抛异常',
      );
    }
    expect(expired, 0);
  });

  test('HTTP 401 触发过期', () {
    var expired = 0;
    final interceptor = SourceAuthInterceptor(
      sourceId: 'test',
      readCredentials: () async => const <String, String>{},
      onSessionExpired: () => expired++,
    );

    interceptor.onResponse(
      response(<String, dynamic>{}, status: 401),
      ResponseInterceptorHandler(),
    );

    expect(expired, 1);
  });

  group('response_decoder 安全读取器', () {
    test('decodeResponseBody 处理 jsonp 包裹', () {
      final decoded = decodeResponseBody('callback({"code":301});');
      expect(asIntOrNull(asMap(decoded)?['code']), 301);
    });

    test('asIntOrNull 兼容 int / double / 数字字符串', () {
      expect(asIntOrNull(8), 8);
      expect(asIntOrNull(8.0), 8);
      expect(asIntOrNull('8'), 8);
      expect(asIntOrNull('abc'), isNull);
      expect(asIntOrNull(null), isNull);
      expect(asIntOrNull(<String, dynamic>{}), isNull);
    });

    test('asStringOrNull / asBoolOrNull / asList / asMap 对错误类型返回 null', () {
      expect(asStringOrNull(1), '1');
      expect(asStringOrNull(<int>[]), isNull);
      expect(asBoolOrNull('true'), isTrue);
      expect(asBoolOrNull(0), isFalse);
      expect(asBoolOrNull('maybe'), isNull);
      expect(asList(<int>[1, 2]), hasLength(2));
      expect(asList('nope'), isNull);
      expect(asMap(<String, int>{'a': 1})?['a'], 1);
      expect(asMap('nope'), isNull);
    });
  });
}
