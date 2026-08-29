import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/utils/cover_network.dart';

void main() {
  test('QQ gtimg 封面带 y.qq.com Referer 和浏览器 UA', () {
    final headers = coverHttpHeaders(
      'https://y.gtimg.cn/music/photo_new/T002R300x300M000001.jpg',
    );
    expect(headers['Referer'], 'https://y.qq.com/');
    expect(headers['User-Agent'], isNot(contains('Dart/')));
  });

  test('网易云 126.net 封面带 music.163.com Referer', () {
    final headers = coverHttpHeaders('https://p1.music.126.net/abc.jpg');
    expect(headers['Referer'], 'https://music.163.com/');
  });

  test('未知主机仍带浏览器 UA，避免 Dart 默认头被拒', () {
    final headers = coverHttpHeaders('https://i.ytimg.com/vi/x/hqdefault.jpg');
    expect(headers['User-Agent'], kCoverUserAgent);
    expect(headers.containsKey('Referer'), isFalse);
  });

  group('normalizeCoverUrl（功耗 PW-11）', () {
    test('网易云：统一 param 到 512y512', () {
      expect(
        normalizeCoverUrl('https://p1.music.126.net/abc.jpg?param=120y120'),
        'https://p1.music.126.net/abc.jpg?param=512y512',
      );
      expect(
        normalizeCoverUrl('https://p2.music.126.net/abc.jpg'),
        'https://p2.music.126.net/abc.jpg?param=512y512',
      );
    });

    test('QQ 音乐：路径内尺寸统一为 500（CDN 无 512 档）', () {
      expect(
        normalizeCoverUrl(
          'https://y.gtimg.cn/music/photo_new/T002R300x300M000001.jpg',
        ),
        'https://y.gtimg.cn/music/photo_new/T002R500x500M000001.jpg',
      );
    });

    test('非网易/QQ 主机原样返回；本地路径不受影响', () {
      const yt = 'https://i.ytimg.com/vi/x/hqdefault.jpg';
      expect(normalizeCoverUrl(yt), yt);
      const file = 'file:///tmp/cover.jpg';
      expect(normalizeCoverUrl(file), file);
      const plain = '/tmp/cover.jpg';
      expect(normalizeCoverUrl(plain), plain);
    });

    test('同尺寸变体归一后字符串一致（缓存命中前提）', () {
      final a = normalizeCoverUrl(
        'https://p1.music.126.net/abc.jpg?param=300y300',
      );
      final b = normalizeCoverUrl('https://p1.music.126.net/abc.jpg');
      expect(a, b);
    });
  });
}
