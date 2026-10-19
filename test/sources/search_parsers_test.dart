import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/sources/netease/netease_source.dart';
import 'package:musaic/sources/qqmusic/qq_music_source.dart';

/// 搜索响应解析：接口变更必须报错，不能伪装成「没有搜索结果」。
void main() {
  group('网易云 parseSearchSongs', () {
    test('cloudsearch 结构（ar/al/dt）', () {
      final tracks = NeteaseSource.parseSearchSongs({
        'code': 200,
        'result': {
          'songs': [
            {
              'id': 1,
              'name': '晴天',
              'ar': [
                {'name': 'A'},
              ],
              'al': {'name': '专辑', 'picUrl': 'http://p1.music.126.net/x.jpg'},
              'dt': 269000,
            },
          ],
        },
      });
      expect(tracks.single.artist, 'A');
      expect(tracks.single.duration, const Duration(seconds: 269));
      expect(tracks.single.coverUrl, startsWith('https://'));
    });

    test('result 被加密成字符串时抛 FormatException', () {
      expect(
        () => NeteaseSource.parseSearchSongs({'result': '35b17489...'}),
        throwsFormatException,
      );
    });

    test('确实没有结果时返回空列表', () {
      expect(
        NeteaseSource.parseSearchSongs({'result': <String, dynamic>{}}),
        isEmpty,
      );
    });
  });

  group('QQ parseFullSearch', () {
    test('解析歌手、时长、专辑封面', () {
      final tracks =
          QqMusicSource.parseFullSearch({
            'data': {
              'song': {
                'list': [
                  {
                    'songmid': '0039MnYb0qxYhV',
                    'songname': '晴天',
                    'singer': [
                      {'name': '周杰伦'},
                    ],
                    'albummid': '000MkMni19ClKG',
                    'albumname': '叶惠美',
                    'interval': 269,
                  },
                ],
              },
            },
          })!;
      expect(tracks.single.artist, '周杰伦');
      expect(tracks.single.duration, const Duration(seconds: 269));
      expect(tracks.single.coverUrl, contains('000MkMni19ClKG'));
      expect(tracks.single.sourceData?['songmid'], '0039MnYb0qxYhV');
    });

    test('结构无法识别时返回 null（退回 smartbox）', () {
      expect(QqMusicSource.parseFullSearch({'code': 0}), isNull);
    });
  });
}
