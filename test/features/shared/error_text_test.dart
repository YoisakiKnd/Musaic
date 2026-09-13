import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/error/source_exception.dart';
import 'package:musaic/core/logging/app_logger.dart';
import 'package:musaic/features/library/data/remote_playlists_provider.dart';
import 'package:musaic/features/shared/error_text.dart';

/// 用户可读错误文案 + 日志去重的回归测试（用户层交互计划 3.4）。
///
/// ## 被固化的缺陷
///
/// 此前多处直接 `Text('加载失败：$e')`，把底层异常原文（含本机绝对路径
/// 的 `PathNotFoundException: ... path = '/data/.../x.json'`）显示给用户：
/// 既不可读，又泄露本机路径。修复后界面只出现「<动作>失败，请重试」，
/// 细节进 [AppLog]。
///
/// ## 为什么必须断言「只记一次」
///
/// 这些文案产生在 `AsyncValue.when(error: ...)` 的 build 回调里，
/// 错误态下每次重建都会再走一遍。若每次都写日志，[AppLog] 的 500 条
/// 环形缓冲会被同一条错误刷满，把「导出诊断日志」的价值冲掉。
/// 因此去重不是优化，而是该功能成立的前提——必须由测试守住。
void main() {
  setUp(AppLog.resetRing);

  group('loadFailureText（计划 3.4）', () {
    test('返回值不含异常原文，只给可读文案', () {
      final error = StateError(
        "PathNotFoundException: Cannot open file, path = '/data/user/0/x.json'",
      );

      final text = loadFailureText(error, tag: 'MusaicTest');

      expect(text, '加载失败，请重试');
      expect(
        text,
        isNot(contains('PathNotFoundException')),
        reason: '异常原文不得出现在界面文案里（不可读且泄露本机路径）',
      );
      expect(text, isNot(contains('/data/')), reason: '不得泄露本机路径');
      expect(text, isNot(contains('StateError')));
    });

    test('prefix 覆盖默认动作词', () {
      final error = StateError('boom');
      expect(
        loadFailureText(error, tag: 'MusaicTest', prefix: '导出失败'),
        '导出失败，请重试',
      );
    });

    test('细节进 AppLog，且带调用方指定的 tag', () {
      final error = StateError('底层细节');

      loadFailureText(error, tag: 'MusaicSearch', prefix: '保存失败');

      final records = AppLog.records;
      expect(records, hasLength(1));
      expect(records.single.tag, 'MusaicSearch');
      expect(
        records.single.message,
        contains('底层细节'),
        reason: '原文要留在日志里，否则线上无从定位',
      );
    });

    test('同一个错误对象重复调用只记一次（防止环形缓冲被刷满）', () {
      final error = StateError('同一个错误');

      // 模拟错误态下的多次重建
      for (var i = 0; i < 5; i++) {
        loadFailureText(error, tag: 'MusaicTest');
      }

      expect(
        AppLog.records,
        hasLength(1),
        reason: '同一错误对象必须只记一次，否则 500 条环形缓冲会被刷满',
      );
    });

    test('不同错误对象各记一次（去重不能误伤真实的新错误）', () {
      loadFailureText(StateError('错误甲'), tag: 'MusaicTest');
      loadFailureText(StateError('错误乙'), tag: 'MusaicTest');

      final messages = AppLog.records.map((r) => r.message).join('\n');
      expect(AppLog.records, hasLength(2));
      expect(messages, contains('错误甲'));
      expect(messages, contains('错误乙'));
    });

    test('不可作 Expando 键的对象不阻断，且仍能返回文案', () {
      // String 是常见的一类「不是合法 Expando 键」的 error 值。
      expect(loadFailureText('字符串错误', tag: 'MusaicTest'), '加载失败，请重试');
      expect(AppLog.records, isNotEmpty, reason: '退化路径也应记日志');
    });
  });

  group('remotePlaylistsErrorMessage（保留渠道侧可读文案）', () {
    test('SourceException 直接采用其 message（渠道已给友好文案）', () {
      final error = NetworkSourceException('网络不可用，请检查连接', sourceId: 'netease');

      expect(remotePlaylistsErrorMessage(error), '网络不可用，请检查连接');
      expect(
        remotePlaylistsErrorMessage(error),
        isNot(contains('SourceException')),
        reason: '不得把异常类型名暴露给用户',
      );
    });

    test('非 SourceException 回退为通用可读文案，并把细节记入日志', () {
      final error = StateError('内部细节');

      expect(remotePlaylistsErrorMessage(error), '加载失败，请重试');
      expect(
        AppLog.records.single.message,
        contains('内部细节'),
        reason: '原文不进界面，但必须留在诊断日志里',
      );
      expect(AppLog.records.single.tag, 'MusaicLibrary');
    });
  });
}
