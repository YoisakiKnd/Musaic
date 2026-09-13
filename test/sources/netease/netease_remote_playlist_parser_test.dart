import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/error/source_exception.dart';
import 'package:musaic/sources/netease/netease_source.dart';

/// 网易云账号歌单解析单测（对齐 QQ 的
/// `test/sources/qqmusic/qq_remote_playlist_parser_test.dart`）。
///
/// 全部用内联 fixture Map，不联网：解析函数是 `static` 且不依赖 Dio，
/// 因此可以脱离渠道实例直接喂「上游可能返回的各种形状」。
///
/// 覆盖四类现实风险：
/// 1. 正常响应（字段路径写对，含毫秒时长语义）；
/// 2. 字段缺失（不能因为少了播放量就整条丢弃）；
/// 3. 结构漂移（上游改层级 / 换类型时**不抛异常**，降级为空列表）；
/// 4. 空数据（未登录、空歌单）。

/// `/api/user/playlist` 响应体的 `playlist` 片段。
List<dynamic> _playlistData() => <dynamic>[
  <String, dynamic>{
    'id': 24381616,
    'name': '我喜欢的音乐',
    'trackCount': 42,
    'playCount': 12345,
    'coverImgUrl': 'http://p1.music.126.net/aaa.jpg',
  },
  <String, dynamic>{
    'id': 5012345678,
    'name': '通勤',
    'trackCount': 8,
    'playCount': 0,
    'coverImgUrl': 'https://p1.music.126.net/bbb.jpg',
  },
];

/// `/api/playlist/detail` 响应体的 `result.tracks` 片段。
List<dynamic> _detailTracksData() => <dynamic>[
  <String, dynamic>{
    'id': 347230,
    'name': '海阔天空',
    'duration': 324000,
    'artists': <dynamic>[
      <String, dynamic>{'id': 2, 'name': 'Beyond'},
    ],
    'album': <String, dynamic>{
      'id': 3,
      'name': '乐与怒',
      'picUrl': 'http://p1.music.126.net/cover.jpg',
    },
  },
  <String, dynamic>{
    'id': 1330348068,
    'name': '光辉岁月',
    'duration': 319000,
    'artists': <dynamic>[
      <String, dynamic>{'id': 2, 'name': 'Beyond'},
      <String, dynamic>{'id': 9, 'name': '黄家驹'},
    ],
    'album': <String, dynamic>{'id': 3, 'name': '乐与怒'},
  },
];

void main() {
  group('parseRemotePlaylists（/api/user/playlist）', () {
    test('正常响应：id / 名称 / 曲目数 / 播放量 / 封面全部落位', () {
      final playlists = NeteaseSource.parseRemotePlaylists(_playlistData());

      expect(playlists, hasLength(2));

      final first = playlists.first;
      expect(first.sourceId, NeteaseSource.id);
      expect(first.id, '24381616');
      expect(first.name, '我喜欢的音乐');
      expect(first.trackCount, 42);
      expect(first.playCount, 12345);
      expect(first.key, 'netease:24381616');
      // http 封面必须升级为 https（Android 默认禁止明文，否则封面全挂）
      expect(first.coverUrl, 'https://p1.music.126.net/aaa.jpg');

      expect(playlists[1].name, '通勤');
      expect(playlists[1].coverUrl, 'https://p1.music.126.net/bbb.jpg');
    });

    test('字段缺失：缺 trackCount / playCount 记 0，缺封面记 null，条目仍保留', () {
      final playlists = NeteaseSource.parseRemotePlaylists(<dynamic>[
        <String, dynamic>{'id': 1, 'name': '只有 id 和名字'},
      ]);

      expect(playlists, hasLength(1));
      expect(playlists.single.trackCount, 0);
      expect(playlists.single.playCount, 0);
      expect(playlists.single.coverUrl, isNull);
    });

    test('字段缺失：id 或名称为空 / 类型不对的条目被丢弃，不污染列表', () {
      final playlists = NeteaseSource.parseRemotePlaylists(<dynamic>[
        <String, dynamic>{'id': 1, 'name': '正常'},
        <String, dynamic>{'name': '没有 id'},
        <String, dynamic>{'id': 2, 'name': ''},
        <String, dynamic>{
          'id': 3,
          'name': <String>['不是字符串'],
        },
        'not-a-map',
        null,
      ]);

      expect(playlists, hasLength(1));
      expect(playlists.single.name, '正常');
    });

    test('id 是数字字符串时仍能解析（接口偶尔返回字符串）', () {
      final playlists = NeteaseSource.parseRemotePlaylists(<dynamic>[
        <String, dynamic>{'id': '999', 'name': '字符串 id'},
      ]);

      expect(playlists.single.id, '999');
    });

    test('结构漂移：playlist 不是数组 / 整块为 null 时返回空列表而非抛异常', () {
      expect(NeteaseSource.parseRemotePlaylists(null), isEmpty);
      expect(NeteaseSource.parseRemotePlaylists('unexpected'), isEmpty);
      expect(NeteaseSource.parseRemotePlaylists(0), isEmpty);
      // 上游把数组包进对象（或换成 Map）——安全读取器应降级成空列表
      expect(
        NeteaseSource.parseRemotePlaylists(<String, dynamic>{
          'list': <dynamic>[],
        }),
        isEmpty,
      );
    });

    test('空数据：未登录 / 无歌单时返回空列表', () {
      expect(NeteaseSource.parseRemotePlaylists(<dynamic>[]), isEmpty);
    });
  });

  group('parseRemotePlaylistTracks（/api/playlist/detail）', () {
    test('正常响应：id / 标题 / 歌手 / 专辑 / 时长（毫秒）/ 封面全部落位', () {
      final tracks = NeteaseSource.parseRemotePlaylistTracks(
        _detailTracksData(),
      );

      expect(tracks, hasLength(2));

      final first = tracks.first;
      expect(first.id, '347230');
      expect(first.sourceId, NeteaseSource.id);
      expect(first.title, '海阔天空');
      expect(first.artist, 'Beyond');
      expect(first.album, '乐与怒');
      // 网易云的 duration 是**毫秒**：若照抄 QQ 的秒语义会得到 90 小时 → 错
      expect(first.duration, const Duration(minutes: 5, seconds: 24));
      expect(first.coverUrl, 'https://p1.music.126.net/cover.jpg');
      // 播放地址靠 neteaseId 解析，sourceData 必须带上
      expect(first.sourceData?['neteaseId'], 347230);

      expect(tracks[1].artist, 'Beyond/黄家驹');
      expect(tracks[1].album, '乐与怒');
      expect(tracks[1].coverUrl, isNull);
    });

    test('字段缺失：缺 artists 记未知歌手、缺 album 记 null、缺 duration 记 null', () {
      final tracks = NeteaseSource.parseRemotePlaylistTracks(<dynamic>[
        <String, dynamic>{'id': 7, 'name': '无歌手无专辑'},
      ]);

      expect(tracks, hasLength(1));
      expect(tracks.single.artist, '未知歌手');
      expect(tracks.single.album, isNull);
      expect(tracks.single.duration, isNull);
      expect(tracks.single.coverUrl, isNull);
    });

    test('字段缺失：缺 id（无法解析播放地址）或标题的条目被丢弃', () {
      final tracks = NeteaseSource.parseRemotePlaylistTracks(<dynamic>[
        <String, dynamic>{'id': 1, 'name': '正常'},
        <String, dynamic>{'name': '没有 id'},
        <String, dynamic>{'id': 2},
        <String, dynamic>{'id': 3, 'name': ''},
        12345,
        null,
      ]);

      expect(tracks, hasLength(1));
      expect(tracks.single.id, '1');
    });

    test('结构漂移：tracks 不是数组 / 整块为 null 时返回空列表而非抛异常', () {
      expect(NeteaseSource.parseRemotePlaylistTracks(null), isEmpty);
      expect(NeteaseSource.parseRemotePlaylistTracks('unexpected'), isEmpty);
      expect(
        NeteaseSource.parseRemotePlaylistTracks(<String, dynamic>{
          'songlist': <dynamic>[],
        }),
        isEmpty,
      );
    });

    test('空歌单：返回空列表（不是失败）', () {
      expect(NeteaseSource.parseRemotePlaylistTracks(<dynamic>[]), isEmpty);
    });
  });

  group('normalizeDioException（失败映射）', () {
    /// 构造一个带可选状态码的 [DioException]。
    DioException dioError({int? statusCode, DioExceptionType? type}) {
      final options = RequestOptions(path: '/api/user/playlist');
      return DioException(
        requestOptions: options,
        type: type ?? DioExceptionType.connectionError,
        response:
            statusCode == null
                ? null
                : Response<dynamic>(
                  requestOptions: options,
                  statusCode: statusCode,
                ),
      );
    }

    test('网络错误 → NetworkSourceException，且消息可读、不带原始堆栈', () {
      final error = NeteaseSource.normalizeDioException(
        dioError(type: DioExceptionType.connectionTimeout),
        '获取账号歌单失败',
      );

      expect(error, isA<NetworkSourceException>());
      expect(error.message, '获取账号歌单失败：网络异常');
      expect(error.sourceId, NeteaseSource.id);
      // UI 直接展示 message，不能把 DioException 原文漏出去
      expect(error.message, isNot(contains('DioException')));
    });

    test('超时同样映射为 NetworkSourceException', () {
      final error = NeteaseSource.normalizeDioException(
        dioError(type: DioExceptionType.receiveTimeout),
        '获取歌单曲目失败',
      );

      expect(error, isA<NetworkSourceException>());
      expect(error.message, '获取歌单曲目失败：网络异常');
    });

    test('HTTP 401 → AuthRequiredException（提示重新登录，而不是「没有歌单」）', () {
      final error = NeteaseSource.normalizeDioException(
        dioError(statusCode: 401),
        '获取账号歌单失败',
      );

      expect(error, isA<AuthRequiredException>());
      expect(error.message, contains('重新登录'));
    });

    test('其他非成功状态码（5xx）→ NetworkSourceException', () {
      final error = NeteaseSource.normalizeDioException(
        dioError(statusCode: 503),
        '获取账号歌单失败',
      );

      expect(error, isA<NetworkSourceException>());
    });
  });
}
