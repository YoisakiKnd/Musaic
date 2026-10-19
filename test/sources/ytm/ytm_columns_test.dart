import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/sources/ytm/ytm_search_parser.dart';

/// YTM 列表项列解析（2026-10 实测结构）：歌手不得混入专辑与播放次数。
void main() {
  Map<String, dynamic> run(String text, [String? pageType]) => {
    'text': text,
    if (pageType != null)
      'navigationEndpoint': {
        'browseEndpoint': {
          'browseEndpointContextSupportedConfigs': {
            'browseEndpointContextMusicConfig': {'pageType': pageType},
          },
        },
      },
  };

  Map<String, dynamic> column(List<Map<String, dynamic>> runs) => {
    'musicResponsiveListItemFlexColumnRenderer': {
      'text': {'runs': runs},
    },
  };

  Map<String, dynamic> item(List<Map<String, dynamic>> second) => {
    'musicResponsiveListItemRenderer': {
      'playlistItemData': {'videoId': 'vid1'},
      'flexColumns': [
        column([run('晴天')]),
        column(second),
        column([run('播放次数：2亿')]),
      ],
    },
  };

  test('歌手 / 专辑 / 时长按链接类型区分，播放次数不进歌手', () {
    final track =
        parseYtmListItem(
          item([
            run('周杰倫', 'MUSIC_PAGE_TYPE_ARTIST'),
            run(' • '),
            run('葉惠美', 'MUSIC_PAGE_TYPE_ALBUM'),
            run(' • '),
            run('4:30'),
          ]),
          sourceId: 'ytm',
        )!;
    expect(track.artist, '周杰倫');
    expect(track.album, '葉惠美');
    expect(track.duration, const Duration(minutes: 4, seconds: 30));
  });

  test('多位歌手都保留', () {
    final track =
        parseYtmListItem(
          item([
            run('A', 'MUSIC_PAGE_TYPE_ARTIST'),
            run(' & '),
            run('B', 'MUSIC_PAGE_TYPE_ARTIST'),
            run(' • '),
            run('专辑', 'MUSIC_PAGE_TYPE_ALBUM'),
          ]),
          sourceId: 'ytm',
        )!;
    expect(track.artist, 'A/B');
  });

  test('歌手无链接时取第一段纯文本，跳过类型标签', () {
    final track =
        parseYtmListItem(
          item([run('歌曲'), run(' • '), run('某频道'), run(' • '), run('3:15')]),
          sourceId: 'ytm',
        )!;
    expect(track.artist, '某频道');
  });

  test('续页 token：首屏与续页两种结构', () {
    final first = {
      'contents': {
        'tabbedSearchResultsRenderer': {
          'tabs': [
            {
              'tabRenderer': {
                'content': {
                  'sectionListRenderer': {
                    'contents': [
                      {
                        'musicShelfRenderer': {
                          'contents': <dynamic>[],
                          'continuations': [
                            {
                              'nextContinuationData': {'continuation': 'T1'},
                            },
                          ],
                        },
                      },
                    ],
                  },
                },
              },
            },
          ],
        },
      },
    };
    expect(extractYtmContinuation(first), 'T1');

    final next = {
      'continuationContents': {
        'musicShelfContinuation': {
          'contents': [
            item([run('X', 'MUSIC_PAGE_TYPE_ARTIST')]),
          ],
        },
      },
    };
    expect(extractYtmContinuation(next), isNull, reason: '最后一页没有 token');
    expect(extractYtmSearchTracks(next, sourceId: 'ytm').single.artist, 'X');
  });
}
