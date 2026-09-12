import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/sources/qqmusic/qq_music_source.dart';

/// QQ 账号歌单解析单测（改进计划 F7 / I4-qq）。
///
/// 全部用内联 fixture Map，不联网：解析函数是 `static` 且不依赖 Dio，
/// 因此可以脱离渠道实例直接喂「上游可能返回的各种形状」。
///
/// 覆盖四类现实风险：
/// 1. 正常响应（字段路径写对）；
/// 2. 字段缺失（不能因为少了播放量就整条丢弃）；
/// 3. 结构漂移（上游改层级 / 换类型时**不抛异常**，降级为空列表）；
/// 4. 空数据（未登录、空歌单）。

/// `music.musicasset.PlaylistBaseRead/GetPlaylistByUin` 的 `req.data` 片段。
Map<String, dynamic> _playlistData() => <String, dynamic>{
  'v_playlist': <dynamic>[
    <String, dynamic>{
      'dissid': 8678123456,
      'dissname': '我喜欢的音乐',
      'song_cnt': 42,
      // 形如 photo_new 的完整 URL：只做尺寸归一化
      'logo': 'https://y.gtimg.cn/music/photo_new/T002R300x300M000aaa.jpg',
      'listennum': 12345,
    },
    <String, dynamic>{
      'dissid': 7012345678,
      'dissname': '通勤',
      'song_cnt': 8,
      'logo': 'T002R300x300M000001Qu4I30eVFYb.jpg',
      'listennum': 0,
    },
  ],
};

/// `music.srfDissInfo.DissInfo/CgiGetDiss` 的 `req.data` 片段。
Map<String, dynamic> _dissData() => <String, dynamic>{
  'songlist': <dynamic>[
    <String, dynamic>{
      'mid': '0039MnYb0qxYhV',
      'name': '晴天',
      'interval': 269,
      'singer': <dynamic>[
        <String, dynamic>{'id': 4558, 'name': '周杰伦'},
      ],
      'album': <String, dynamic>{'mid': '000MkMni19ClKG', 'name': '叶惠美'},
    },
    <String, dynamic>{
      'mid': '004Z8Ihr0JIu5s',
      'name': '以父之名',
      'interval': 342,
      'singer': <dynamic>[
        <String, dynamic>{'id': 4558, 'name': '周杰伦'},
        <String, dynamic>{'id': 1234, 'name': '袁咏琳'},
      ],
      'album': <String, dynamic>{'mid': '000MkMni19ClKG', 'name': '叶惠美'},
    },
  ],
};

void main() {
  group('parseRemotePlaylists（v_playlist）', () {
    test('正常响应：dissid / dissname / song_cnt / listennum / logo 全部落位', () {
      final playlists = QqMusicSource.parseRemotePlaylists(
        _playlistData()['v_playlist'],
      );

      expect(playlists, hasLength(2));

      final first = playlists.first;
      expect(first.sourceId, QqMusicSource.id);
      expect(first.id, '8678123456');
      expect(first.name, '我喜欢的音乐');
      expect(first.trackCount, 42);
      expect(first.playCount, 12345);
      // 封面必须已归一化到 R500x500M，否则与列表页各下各的图（PW-11）
      expect(first.coverUrl, contains('R500x500M'));
      expect(first.key, 'qqmusic:8678123456');

      final second = playlists[1];
      expect(second.id, '7012345678');
      // 裸文件名（无 http 前缀）要补 y.gtimg.cn 前缀
      expect(
        second.coverUrl,
        'https://y.gtimg.cn/music/photo_new/T002R500x500M000001Qu4I30eVFYb.jpg',
      );
    });

    test('封面：qpic.cn 完整 URL 原样保留（无尺寸段可归一化，不强改路径）', () {
      final playlists = QqMusicSource.parseRemotePlaylists(<dynamic>[
        <String, dynamic>{
          'dissid': 5,
          'dissname': '封面是 qpic',
          'logo': 'https://p.qpic.cn/music_cover/abc/300?n=1',
        },
      ]);

      expect(
        playlists.single.coverUrl,
        'https://p.qpic.cn/music_cover/abc/300?n=1',
      );
    });

    test('字段缺失：缺 song_cnt 记 0、缺 listennum 记 null，条目仍保留', () {
      final playlists = QqMusicSource.parseRemotePlaylists(<dynamic>[
        <String, dynamic>{'dissid': 1, 'dissname': '只有 id 和名字'},
      ]);

      expect(playlists, hasLength(1));
      expect(playlists.single.trackCount, 0);
      // 模型语义是「渠道不提供」→ null，UI 据此隐去「N 次播放」
      expect(playlists.single.playCount, isNull);
      expect(playlists.single.coverUrl, isNull);
    });

    test('字段缺失：id 或名称为空 / 类型不对的条目被丢弃，不污染列表', () {
      final playlists = QqMusicSource.parseRemotePlaylists(<dynamic>[
        <String, dynamic>{'dissid': 1, 'dissname': '正常'},
        <String, dynamic>{'dissname': '没有 id'},
        <String, dynamic>{'dissid': 2, 'dissname': ''},
        <String, dynamic>{
          'dissid': 3,
          'dissname': <String>['不是字符串'],
        },
        'not-a-map',
        null,
      ]);

      expect(playlists, hasLength(1));
      expect(playlists.single.name, '正常');
    });

    test('结构漂移：v_playlist 不是数组 / 整块为 null 时返回空列表而非抛异常', () {
      expect(
        QqMusicSource.parseRemotePlaylists(<String, dynamic>{
          'v_playlist': <dynamic>[],
        }),
        isEmpty,
      );
      // 上游把数组包进对象（或换成 Map）——安全读取器应降级成空列表
      expect(
        QqMusicSource.parseRemotePlaylists(<String, dynamic>{
          'v_playlist': <String, dynamic>{'list': <dynamic>[]},
        }),
        isEmpty,
      );
      expect(QqMusicSource.parseRemotePlaylists(null), isEmpty);
      expect(QqMusicSource.parseRemotePlaylists('unexpected'), isEmpty);
      expect(QqMusicSource.parseRemotePlaylists(0), isEmpty);
    });

    test('空数据：未登录 / 无歌单时返回空列表', () {
      expect(QqMusicSource.parseRemotePlaylists(<dynamic>[]), isEmpty);
      expect(
        QqMusicSource.parseRemotePlaylists(_playlistData()['missing']),
        isEmpty,
      );
    });

    test('结构漂移：dissid 是数字字符串时仍能解析', () {
      final playlists = QqMusicSource.parseRemotePlaylists(<dynamic>[
        <String, dynamic>{'dissid': '999', 'dissname': '字符串 id'},
      ]);

      expect(playlists.single.id, '999');
    });
  });

  group('parseRemotePlaylistTracks（songlist）', () {
    test('正常响应：mid / 标题 / 歌手 / 专辑 / 时长（秒）/ 封面全部落位', () {
      final tracks = QqMusicSource.parseRemotePlaylistTracks(
        _dissData()['songlist'],
      );

      expect(tracks, hasLength(2));

      final first = tracks.first;
      expect(first.id, '0039MnYb0qxYhV');
      expect(first.sourceId, QqMusicSource.id);
      expect(first.title, '晴天');
      expect(first.artist, '周杰伦');
      expect(first.album, '叶惠美');
      // QQ 的 interval 是**秒**：若照抄网易云的毫秒语义会得到 4 分半 → 错
      expect(first.duration, const Duration(minutes: 4, seconds: 29));
      expect(
        first.coverUrl,
        'https://y.gtimg.cn/music/photo_new/T002R500x500M000000MkMni19ClKG.jpg',
      );
      // 播放地址靠 songmid 解析，sourceData 必须带上
      expect(first.sourceData?['songmid'], '0039MnYb0qxYhV');

      expect(tracks[1].artist, '周杰伦/袁咏琳');
    });

    test('字段缺失：缺 singer 记未知歌手、缺 album 记 null、缺 interval 记 null', () {
      final tracks = QqMusicSource.parseRemotePlaylistTracks(<dynamic>[
        <String, dynamic>{'mid': 'aaa', 'name': '无歌手无专辑'},
      ]);

      expect(tracks, hasLength(1));
      expect(tracks.single.artist, '未知歌手');
      expect(tracks.single.album, isNull);
      expect(tracks.single.duration, isNull);
      expect(tracks.single.coverUrl, isNull);
    });

    test('字段缺失：缺 mid（无法解析播放地址）或标题的条目被丢弃', () {
      final tracks = QqMusicSource.parseRemotePlaylistTracks(<dynamic>[
        <String, dynamic>{'mid': 'ok', 'name': '正常'},
        <String, dynamic>{'name': '没有 mid'},
        <String, dynamic>{'mid': 'bbb'},
        <String, dynamic>{'mid': '', 'name': '空 mid'},
        <String, dynamic>{'mid': 'ccc', 'name': ''},
        12345,
        null,
      ]);

      expect(tracks, hasLength(1));
      expect(tracks.single.id, 'ok');
    });

    test('结构漂移：songlist 不是数组时返回空列表而非抛异常', () {
      expect(
        QqMusicSource.parseRemotePlaylistTracks(<String, dynamic>{
          'songlist': <dynamic>[],
        }),
        isEmpty,
      );
      expect(
        QqMusicSource.parseRemotePlaylistTracks(<String, dynamic>{
          'songlist': <String, dynamic>{'song': <dynamic>[]},
        }),
        isEmpty,
      );
      expect(QqMusicSource.parseRemotePlaylistTracks(null), isEmpty);
      expect(QqMusicSource.parseRemotePlaylistTracks(3.14), isEmpty);
    });

    test('结构漂移：singer 是字符串而非数组、album 是字符串时不抛异常', () {
      final tracks = QqMusicSource.parseRemotePlaylistTracks(<dynamic>[
        <String, dynamic>{
          'mid': 'ddd',
          'name': '漂移字段',
          'singer': '周杰伦',
          'album': '叶惠美',
          'interval': '300',
        },
      ]);

      expect(tracks, hasLength(1));
      // singer 无法按数组解析 → 降级为未知歌手（而不是崩溃）
      expect(tracks.single.artist, '未知歌手');
      expect(tracks.single.album, isNull);
      // 数字字符串仍可安全转 int
      expect(tracks.single.duration, const Duration(minutes: 5));
    });

    test('空数据：空歌单返回空列表', () {
      expect(QqMusicSource.parseRemotePlaylistTracks(<dynamic>[]), isEmpty);
      expect(
        QqMusicSource.parseRemotePlaylistTracks(_dissData()['missing']),
        isEmpty,
      );
    });
  });
}
