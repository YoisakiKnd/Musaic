import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/utils/url_utils.dart';

/// URL 清理工具（T3 边界异常测试，此前无直接测试）。
///
/// `toHttps()` 存在的理由很实际：Android 默认禁止明文 HTTP，
/// 部分渠道返回 http 图链会导致**封面全部加载失败**。
void main() {
  group('toHttps', () {
    test('http:// 升级为 https://', () {
      expect(
        'http://p1.music.126.net/cover.jpg'.toHttps(),
        'https://p1.music.126.net/cover.jpg',
      );
    });

    test('已是 https 保持不变', () {
      const url = 'https://p1.music.126.net/cover.jpg';
      expect(url.toHttps(), url);
    });

    test('null 安全返回 null', () {
      const String? url = null;
      expect(url.toHttps(), isNull);
    });

    test('空串原样返回', () {
      expect(''.toHttps(), '');
    });

    test('只替换开头的 http://，不误伤路径中的同名片段', () {
      expect(
        'http://example.com/a?next=http://other'.toHttps(),
        'https://example.com/a?next=http://other',
      );
    });

    test('非 http 协议不处理', () {
      for (final url in <String>[
        'ftp://example.com/a',
        'file:///music/a.mp3',
        'data:image/png;base64,AAAA',
        'musaic://netease/1',
      ]) {
        expect(url.toHttps(), url, reason: url);
      }
    });

    test('裸路径与相对路径不处理', () {
      expect('/music/a.mp3'.toHttps(), '/music/a.mp3');
      expect('a/b.jpg'.toHttps(), 'a/b.jpg');
    });

    test('大写 HTTP:// 不匹配（Dart startsWith 区分大小写）', () {
      // 记录当前行为：URL scheme 规范上大小写不敏感，
      // 但渠道实际只返回小写；此处固化行为避免无意改动。
      expect('HTTP://example.com'.toHttps(), 'HTTP://example.com');
    });

    test('超长 URL 不抛异常', () {
      final long = 'http://example.com/${'a' * 10000}';
      expect(long.toHttps, returnsNormally);
    });

    test('中文与特殊字符路径保持完整', () {
      expect(
        'http://example.com/音乐/封面 图.jpg'.toHttps(),
        'https://example.com/音乐/封面 图.jpg',
      );
    });
  });
}
