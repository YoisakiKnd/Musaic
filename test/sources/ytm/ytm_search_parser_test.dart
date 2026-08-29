import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/sources/ytm/ytm_search_parser.dart';

Map<String, dynamic> _wrappedSong() => <String, dynamic>{
      'musicResponsiveListItemRenderer': <String, dynamic>{
        'playlistItemData': <String, dynamic>{'videoId': 'abc123'},
        'flexColumns': <dynamic>[
          <String, dynamic>{
            'musicResponsiveListItemFlexColumnRenderer': <String, dynamic>{
              'text': <String, dynamic>{
                'runs': <dynamic>[
                  <String, dynamic>{'text': '晴天'},
                ],
              },
            },
          },
          <String, dynamic>{
            'musicResponsiveListItemFlexColumnRenderer': <String, dynamic>{
              'text': <String, dynamic>{
                'runs': <dynamic>[
                  <String, dynamic>{'text': '周杰伦'},
                  <String, dynamic>{'text': '3:45'},
                ],
              },
            },
          },
        ],
        'thumbnail': <String, dynamic>{
          'musicThumbnailRenderer': <String, dynamic>{
            'thumbnail': <String, dynamic>{
              'thumbnails': <dynamic>[
                <String, dynamic>{'url': 'https://i.ytimg.com/vi/abc123/hq.jpg'},
              ],
            },
          },
        },
      },
    };

void main() {
  test('解开 musicResponsiveListItemRenderer 包装', () {
    final track = parseYtmListItem(_wrappedSong(), sourceId: 'ytmusic');
    expect(track, isNotNull);
    expect(track!.id, 'abc123');
    expect(track.title, '晴天');
    expect(track.artist, '周杰伦');
    expect(track.duration, const Duration(minutes: 3, seconds: 45));
    expect(track.coverUrl, contains('ytimg.com'));
  });

  test('twoColumnSearchResultsRenderer 能抽出歌曲', () {
    final root = <String, dynamic>{
      'contents': <String, dynamic>{
        'twoColumnSearchResultsRenderer': <String, dynamic>{
          'primaryContents': <String, dynamic>{
            'sectionListRenderer': <String, dynamic>{
              'contents': <dynamic>[
                <String, dynamic>{
                  'musicShelfRenderer': <String, dynamic>{
                    'contents': <dynamic>[_wrappedSong()],
                  },
                },
              ],
            },
          },
        },
      },
    };
    final tracks = extractYtmSearchTracks(root, sourceId: 'ytmusic');
    expect(tracks, hasLength(1));
    expect(tracks.first.title, '晴天');
  });

  test('tabbedSearchResultsRenderer 仍可用', () {
    final root = <String, dynamic>{
      'contents': <String, dynamic>{
        'tabbedSearchResultsRenderer': <String, dynamic>{
          'tabs': <dynamic>[
            <String, dynamic>{
              'tabRenderer': <String, dynamic>{
                'content': <String, dynamic>{
                  'sectionListRenderer': <String, dynamic>{
                    'contents': <dynamic>[
                      <String, dynamic>{
                        'musicShelfRenderer': <String, dynamic>{
                          'contents': <dynamic>[_wrappedSong()],
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
    final tracks = extractYtmSearchTracks(root, sourceId: 'ytmusic');
    expect(tracks.single.id, 'abc123');
  });
}
