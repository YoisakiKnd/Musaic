import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/logging/app_logger.dart';

/// 日志脱敏（迭代计划 H4 / 改进计划 I1-logs，🔴P0）。
///
/// 触发本模块的真实缺陷：网易云 `createQrLogin` 曾把整个响应体写进日志，
/// 其中含登录 `unikey`；酷狗曾把 token/userid 放进 URL query。
void main() {
  setUp(AppLog.resetRing);

  group('redactForLog 凭据遮蔽', () {
    test('query 参数中的 token / unikey 被遮蔽', () {
      final out = redactForLog(
        'GET https://example.com/api?token=abc123&userid=99887&cmd=play',
      );
      expect(out, isNot(contains('abc123')));
      expect(out, isNot(contains('99887')));
      expect(out, contains('token=***'));
      // 非敏感参数也应被 query 兜底规则遮蔽（白名单不可穷尽）
      expect(out, contains('cmd=***'));
    });

    test('JSON 体中的 MUSIC_U / musickey 被遮蔽', () {
      final out = redactForLog(
        '{"code":200,"MUSIC_U":"deadbeefcafe","musickey":"xyz","nickname":"n"}',
      );
      expect(out, isNot(contains('deadbeefcafe')));
      expect(out, isNot(contains('"xyz"')));
      expect(out, contains('MUSIC_U=***'));
      expect(out, contains('musickey=***'));
      // 非敏感字段保留，便于排障
      expect(out, contains('"code":200'));
    });

    test('Cookie / Authorization 头被遮蔽', () {
      final out = redactForLog(
        'headers={Cookie: MUSIC_U=secretvalue; os=pc, '
        'authorization: Bearer ya29.abcdefghijklmnop}',
      );
      expect(out, isNot(contains('secretvalue')));
      expect(out, isNot(contains('ya29.abcdefghijklmnop')));
    });

    test('Bearer / Basic 令牌被遮蔽', () {
      expect(
        redactForLog('Authorization: Bearer abc.def.ghi'),
        isNot(contains('abc.def.ghi')),
      );
      expect(
        redactForLog('Authorization: Basic dXNlcjpwYXNz'),
        isNot(contains('dXNlcjpwYXNz')),
      );
    });

    test('URL 编码的 %3D 分隔同样命中', () {
      final out = redactForLog('unikey%3Dabcdef123456');
      expect(out, isNot(contains('abcdef123456')));
    });

    test('SAPISID / vkey / purl 等渠道凭据被遮蔽', () {
      final out = redactForLog(
        'SAPISID=abcdefghijkl; vkey=9876543210; purl=https://x/y?k=1',
      );
      expect(out, isNot(contains('abcdefghijkl')));
      expect(out, isNot(contains('9876543210')));
    });

    test('普通文本不被改动', () {
      const plain = 'MusaicPlayer stream: source=netease (local=false)';
      expect(redactForLog(plain), plain);
    });

    test('空串安全', () {
      expect(redactForLog(''), '');
    });

    test('大小写不敏感', () {
      final out = redactForLog('TOKEN=abc123 secret=def456');
      expect(out, isNot(contains('abc123')));
      expect(out, isNot(contains('def456')));
    });
  });

  group('AppLog 环形缓冲', () {
    test('写入后可按标签与级别取回', () {
      AppLog.info('启动完成', tag: 'TestTag');
      AppLog.warning('弱网', tag: 'TestTag');

      final records = AppLog.records;
      expect(records, hasLength(2));
      expect(records.first.tag, 'TestTag');
      expect(records.first.level, AppLogLevel.info);
      expect(records.last.level, AppLogLevel.warning);
    });

    test('缓冲内容本身已脱敏（不只是输出通道）', () {
      AppLog.info('token=supersecret', tag: 'TestTag');
      expect(AppLog.exportText(), isNot(contains('supersecret')));
      expect(AppLog.records.single.message, contains('token=***'));
    });

    test('环形缓冲不超过容量', () {
      for (var i = 0; i < AppLog.ringCapacity + 50; i++) {
        AppLog.info('entry $i');
      }
      expect(AppLog.records, hasLength(AppLog.ringCapacity));
      // 最旧的被淘汰，最新的保留
      expect(AppLog.records.last.message, 'entry ${AppLog.ringCapacity + 49}');
    });

    test('error 携带异常与堆栈首行', () {
      AppLog.error(
        '播放失败',
        tag: 'TestTag',
        error: StateError('boom'),
        stackTrace: StackTrace.current,
      );
      final message = AppLog.records.single.message;
      expect(message, contains('播放失败'));
      expect(message, contains('boom'));
      expect(message, contains('stack='));
    });

    test('exportText 逐行渲染且已脱敏', () {
      AppLog.info('unikey=leakme');
      final text = AppLog.exportText();
      expect(text, contains('[INFO]'));
      expect(text, isNot(contains('leakme')));
    });
  });
}
