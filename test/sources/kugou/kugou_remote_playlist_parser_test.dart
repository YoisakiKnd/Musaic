import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/error/source_exception.dart';
import 'package:musaic/sources/kugou/kugou_source.dart';

/// 酷狗账号歌单解析单测（对齐
/// `test/sources/netease/netease_remote_playlist_parser_test.dart`）。
///
/// 全部用内联 fixture Map，不联网：解析函数是 `static` 且不依赖 Dio，
/// 因此可以脱离渠道实例直接喂「上游可能返回的各种形状」。
///
/// 字段与签名规则来自 MIT 许可的参考实现 MakcRe/KuGouMusicApi
/// （Copyright 2023 MakcRe，MIT License）：
/// `module/top_playlist.js`、`module/playlist_track_all.js`、
/// `module/playlist_detail.js`、`util/helper.js`；
/// 签名与响应字段另经真实网关实测（2026-09-13）确认。
///
/// 覆盖四类现实风险：
/// 1. 正常响应（`special_list` / `songs` 字段路径写对，含毫秒时长语义）；
/// 2. 字段缺失（少了播放量 / 封面不能整条丢弃）；
/// 3. 结构漂移（上游改层级 / 换类型时**不抛异常**，降级为空列表）；
/// 4. 空数据（空歌单、越界分页、占位曲目）。

/// `POST /v2/special_recommend` 响应体的 `data.special_list` 片段。
///
/// 字段取自真实响应（2026-09-13 实测）。
List<dynamic> _specialListData() => <dynamic>[
  <String, dynamic>{
    'global_collection_id': 'collection_1_1286024014_710163_0',
    'specialid': 710163,
    'specialname': '高考过后Relax：放松心情，调整作息',
    'imgurl':
        'http://imge.kugou.com/soft/collection/{size}/20190606/20190606002605940380.jpg',
    'play_count': 2113985,
    // 发现接口的 percount 恒为 0，collectcount 是收藏人数而非曲目数
    'percount': 0,
    'collectcount': 11934,
  },
  <String, dynamic>{
    'global_collection_id': 'collection_3_1022509336_21_0',
    'specialid': 6471626,
    'specialname': '2022-2023香港乐坛粤语新歌',
    'flexible_cover': 'http://c1.kgimg.com/custom/{size}/20230201/aaa.jpg',
    'play_count': 9195836,
  },
];

/// `GET /pubsongs/v2/get_other_list_file_nofilt` 响应体的 `data.songs` 片段。
///
/// 含一个**真实出现过的占位项**（只有 fileid/shield，无 name/hash）。
List<dynamic> _songsData() => <dynamic>[
  <String, dynamic>{'fileid': 26, 'shield': 1},
  <String, dynamic>{
    'hash': '5336EB3A757F32B590A6C7A6B666383D',
    'audio_id': 476591110,
    'name': 'Supper Moment - 谢谢你啊世界',
    'timelen': 351000,
    'album_id': '154759251',
    'albuminfo': <String, dynamic>{'name': '谢谢你啊世界', 'id': 154759251},
    'singerinfo': <dynamic>[
      <String, dynamic>{'name': 'Supper Moment', 'id': 8720},
    ],
    'cover':
        'http://imge.kugou.com/stdmusic/{size}/20250717/20250717162501185486.jpg',
    'privilege': 8,
    'feetype': 0,
  },
  <String, dynamic>{
    'hash': '76E36C9C07DBB8A1AE0E457EF237113C',
    'name': '平井真美子 - 孤灯',
    'timelen': 154174,
    'singerinfo': <dynamic>[
      <String, dynamic>{'name': '平井真美子', 'id': 202688},
    ],
    'albuminfo': <String, dynamic>{
      'name': '映画 『白夜行』 オリジナル.サウンドトラック',
      'id': 18747020,
    },
    'cover': 'http://imge.kugou.com/stdmusic/{size}/20190318/aaa.jpg',
  },
];

void main() {
  group('parseRemotePlaylists（歌单列表）', () {
    test('正常响应：解析出 id / 名称 / 播放量 / 封面并升级为 https', () {
      final playlists = KugouSource.parseRemotePlaylists(_specialListData());

      expect(playlists, hasLength(2));
      final first = playlists.first;
      expect(first.sourceId, KugouSource.id);
      expect(first.id, 'collection_1_1286024014_710163_0');
      expect(first.name, '高考过后Relax：放松心情，调整作息');
      expect(first.playCount, 2113985);
      // 封面带 {size} 占位符，且 http → https（Android 禁明文）
      expect(first.coverUrl, contains('240'));
      expect(first.coverUrl, startsWith('https://'));
      expect(first.coverUrl, isNot(contains('{size}')));
      expect(first.key, 'kugou:collection_1_1286024014_710163_0');
    });

    test('发现接口不提供曲目数：trackCount 记 0，由批量详情补齐', () {
      final playlists = KugouSource.parseRemotePlaylists(_specialListData());

      // percount 恒为 0、collectcount 是收藏人数，都不是曲目数
      expect(playlists.every((p) => p.trackCount == 0), isTrue);
    });

    test('缺 id / 缺名称的条目被丢弃（渲染出来是点不动的空白卡片）', () {
      final playlists = KugouSource.parseRemotePlaylists(<dynamic>[
        <String, dynamic>{'specialname': '没有 id'},
        <String, dynamic>{'global_collection_id': 'x', 'specialname': ''},
        <String, dynamic>{'global_collection_id': 'y', 'specialname': '   '},
        <String, dynamic>{'global_collection_id': 'ok', 'specialname': '正常'},
      ]);

      expect(playlists, hasLength(1));
      expect(playlists.single.id, 'ok');
    });

    test('字段缺失：缺播放量记 null、缺封面记 null，条目仍保留', () {
      final playlists = KugouSource.parseRemotePlaylists(<dynamic>[
        <String, dynamic>{
          'global_collection_id': 'collection_9_1_2_0',
          'specialname': '无播放量与封面',
        },
      ]);

      expect(playlists, hasLength(1));
      expect(playlists.single.playCount, isNull);
      expect(playlists.single.coverUrl, isNull);
    });

    test('结构漂移：special_list 非数组 / 整块为 null 时降级为空列表且不抛异常', () {
      expect(KugouSource.parseRemotePlaylists(null), isEmpty);
      expect(KugouSource.parseRemotePlaylists('not-a-list'), isEmpty);
      expect(KugouSource.parseRemotePlaylists(<String, dynamic>{}), isEmpty);
      // 元素不是 Map 也要跳过而不是崩
      expect(
        KugouSource.parseRemotePlaylists(<dynamic>[1, 'x', null]),
        isEmpty,
      );
    });
  });

  group('parseKugouSong（歌单曲目）', () {
    test('正常响应：剥离「歌手 - 」前缀、毫秒时长、封面升级 https', () {
      final tracks =
          <dynamic>[
            for (final song in _songsData()) KugouSource.parseKugouSong(song),
          ].whereType<Object>().toList();

      // 占位项被丢弃，剩 2 首
      expect(tracks, hasLength(2));

      final first = KugouSource.parseKugouSong(_songsData()[1])!;
      expect(first.id, '5336EB3A757F32B590A6C7A6B666383D');
      expect(first.sourceId, KugouSource.id);
      expect(first.title, '谢谢你啊世界');
      expect(first.artist, 'Supper Moment');
      expect(first.album, '谢谢你啊世界');
      // timelen 是毫秒：351000ms = 5分51秒（照抄 QQ 的秒会得到 97 小时）
      expect(first.duration, const Duration(minutes: 5, seconds: 51));
      expect(first.coverUrl, startsWith('https://'));
      expect(first.coverUrl, isNot(contains('{size}')));
      expect(first.sourceData?['hash'], first.id);
      expect(first.sourceData?['albumId'], '154759251');
    });

    test('占位项（只有 fileid/shield，无 hash/name）被丢弃', () {
      expect(
        KugouSource.parseKugouSong(<String, dynamic>{
          'fileid': 26,
          'shield': 1,
        }),
        isNull,
      );
    });

    test('缺 hash 或空标题的条目被丢弃', () {
      expect(
        KugouSource.parseKugouSong(<String, dynamic>{'name': '有标题无 hash'}),
        isNull,
      );
      expect(
        KugouSource.parseKugouSong(<String, dynamic>{
          'hash': 'ABC',
          'name': '   ',
        }),
        isNull,
      );
      expect(
        KugouSource.parseKugouSong(<String, dynamic>{
          'hash': '',
          'name': '空 hash',
        }),
        isNull,
      );
    });

    test('多歌手用 / 连接；标题自身含「-」时不被误切', () {
      final multi =
          KugouSource.parseKugouSong(<String, dynamic>{
            'hash': 'H1',
            'name': 'A - B - 歌名',
            'singerinfo': <dynamic>[
              <String, dynamic>{'name': 'A'},
              <String, dynamic>{'name': 'B'},
            ],
          })!;
      // singerinfo 拼接为 'A/B'，与 'A - B' 前缀不一致 → 保留完整 name 作标题
      expect(multi.artist, 'A/B');
      expect(multi.title, 'A - B - 歌名');
    });

    test('无 singerinfo 时从「歌手 - 标题」前缀取歌手，缺则记未知歌手', () {
      final fromName =
          KugouSource.parseKugouSong(<String, dynamic>{
            'hash': 'H2',
            'name': '周杰伦 - 晴天',
          })!;
      expect(fromName.artist, '周杰伦');
      expect(fromName.title, '晴天');

      final noArtist =
          KugouSource.parseKugouSong(<String, dynamic>{
            'hash': 'H3',
            'name': '纯标题',
          })!;
      expect(noArtist.artist, '未知歌手');
      expect(noArtist.title, '纯标题');
    });

    test('时长缺失或非正数记 null（不能变成 0 秒）', () {
      expect(
        KugouSource.parseKugouSong(<String, dynamic>{
          'hash': 'H4',
          'name': 'a - b',
        })!.duration,
        isNull,
      );
      expect(
        KugouSource.parseKugouSong(<String, dynamic>{
          'hash': 'H5',
          'name': 'a - b',
          'timelen': 0,
        })!.duration,
        isNull,
      );
    });

    test('结构漂移：非 Map 输入返回 null 而不是抛异常', () {
      expect(KugouSource.parseKugouSong(null), isNull);
      expect(KugouSource.parseKugouSong('x'), isNull);
      expect(KugouSource.parseKugouSong(<dynamic>[]), isNull);
      // 类型漂移：hash 是数字时 asStringOrNull 仍能取到
      expect(
        KugouSource.parseKugouSong(<String, dynamic>{
          'hash': 123,
          'name': 'a - b',
        })?.id,
        '123',
      );
    });
  });

  group('androidSignature（签名算法）', () {
    // 固定参数下的确定性向量：签名错一个字符网关就报 200101。
    // 注意：签名覆盖的 body 必须与实际发送的字符串完全一致；
    // 参数值中的对象 / 数组用紧凑 JSON（对齐参考实现的 JSON.stringify）。
    test('GET 形态（空 body）：与参考实现算法一致', () {
      final params = <String, dynamic>{
        'appid': '1005',
        'clienttime': '1700000000',
        'clientver': '20489',
        'dfid': '-',
        'mid': '0123456789abcdef0123456789abcdef',
        'uuid': '-',
      };

      expect(
        KugouSource.androidSignature(params, ''),
        '21979dbffb87eb19027ed25c96c94a4d',
      );
    });

    test('POST 形态：body 参与签名', () {
      final params = <String, dynamic>{
        'appid': '1005',
        'clienttime': '1700000000',
        'clientver': '20489',
        'dfid': '-',
        'mid': '0123456789abcdef0123456789abcdef',
        'uuid': '-',
      };
      const body =
          '{"page":1,"special_recommend":{"area_code":1,"categoryid":0}}';

      expect(
        KugouSource.androidSignature(params, body),
        '1f935c5213b0d933584d9c1b89e67691',
      );
    });

    test('参数按 key 排序，顺序不影响结果', () {
      final a = <String, dynamic>{'b': '2', 'a': '1'};
      final b = <String, dynamic>{'a': '1', 'b': '2'};

      expect(
        KugouSource.androidSignature(a, ''),
        KugouSource.androidSignature(b, ''),
      );
    });

    test('androidParamsKey：发现接口的 key 参数', () {
      expect(
        KugouSource.androidParamsKey('1700000000'),
        'a1f65b6a8fe7e191521406ce8661ae02',
      );
    });
  });

  group('throwIfFailed（业务失败判定）', () {
    test('status 1 / error_code 0 → 不抛（成功）', () {
      expect(
        () => KugouSource.throwIfFailed(<String, dynamic>{
          'status': 1,
          'error_code': 0,
          'data': <dynamic>[],
        }, '获取账号歌单失败'),
        returnsNormally,
      );
    });

    test('status 0 → NetworkSourceException（带错误码，便于定位）', () {
      expect(
        () => KugouSource.throwIfFailed(<String, dynamic>{
          'status': 0,
          'error_code': 20010,
        }, '获取账号歌单失败'),
        throwsA(
          isA<NetworkSourceException>()
              .having((e) => e.message, 'message', contains('20010'))
              .having((e) => e.sourceId, 'sourceId', KugouSource.id),
        ),
      );
    });

    test('error_code 非 0（签名错 200101）同样视为失败', () {
      expect(
        () => KugouSource.throwIfFailed(<String, dynamic>{
          'status': 0,
          'error_code': 200101,
        }, '获取账号歌单失败'),
        throwsA(isA<NetworkSourceException>()),
      );
    });

    test('无效歌单 id 返回 data {} / status 1 / error_code 0 → 属空结果，不抛异常', () {
      // 实测：不存在的 global_collection_id 就是这个形状，
      // 与「真的没有数据」不可区分，因此必须按空结果处理。
      expect(
        () => KugouSource.throwIfFailed(<String, dynamic>{
          'error_code': 0,
          'errmsg': '',
          'data': <String, dynamic>{},
          'status': 1,
        }, '获取歌单曲目失败'),
        returnsNormally,
      );
    });

    test('响应不是 Map（HTML 错误页等）→ 交给上层，不在这里抛', () {
      expect(
        () => KugouSource.throwIfFailed('<html>502 Bad Gateway</html>', 'x'),
        returnsNormally,
      );
      expect(() => KugouSource.throwIfFailed(null, 'x'), returnsNormally);
    });
  });

  group('normalizeDioException（失败映射）', () {
    DioException dioError({int? statusCode, DioExceptionType? type}) {
      final options = RequestOptions(path: '/x');
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

    test('网络错误 → NetworkSourceException，消息可读、不含 DioException 原文', () {
      final error = KugouSource.normalizeDioException(
        dioError(type: DioExceptionType.connectionTimeout),
        '获取账号歌单失败',
      );

      expect(error, isA<NetworkSourceException>());
      expect(error.message, '获取账号歌单失败：网络异常');
      expect(error.sourceId, KugouSource.id);
      expect(error.message, isNot(contains('DioException')));
    });

    test('超时同样映射为 NetworkSourceException', () {
      final error = KugouSource.normalizeDioException(
        dioError(type: DioExceptionType.receiveTimeout),
        '获取歌单曲目失败',
      );

      expect(error, isA<NetworkSourceException>());
      expect(error.message, '获取歌单曲目失败：网络异常');
    });

    test('HTTP 401 → AuthRequiredException（提示重新登录）', () {
      final error = KugouSource.normalizeDioException(
        dioError(statusCode: 401),
        '获取账号歌单失败',
      );

      expect(error, isA<AuthRequiredException>());
      expect(error.message, contains('重新登录'));
    });

    test('其他非成功状态码（5xx）→ NetworkSourceException', () {
      final error = KugouSource.normalizeDioException(
        dioError(statusCode: 503),
        '获取账号歌单失败',
      );

      expect(error, isA<NetworkSourceException>());
    });
  });
}
