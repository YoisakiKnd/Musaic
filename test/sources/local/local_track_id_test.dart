import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/error/source_exception.dart';
import 'package:musaic/core/model/track.dart';
import 'package:musaic/sources/local/local_file_source.dart';

/// 本地曲目稳定 id（架构演进 §3.3 / 日常可用性计划 D9）。
///
/// 核心诉求：id 由**内容指纹**（文件大小 + 前 64KB 哈希）决定，而不是绝对路径。
/// 用户移动 / 重命名音乐目录是本地曲库的常态，旧实现（id = 绝对路径）
/// 会让收藏与歌单里的曲目静默失效。
void main() {
  late Directory tempDir;
  late Directory coverDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_local_id');
    coverDir = await Directory.systemTemp.createTemp('musaic_local_id_cover');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    if (coverDir.existsSync()) await coverDir.delete(recursive: true);
  });

  LocalFileSource buildSource(Directory dir) => LocalFileSource(
    credentialReader: () async => <String, String>{},
    directoryProvider: () async => [dir],
    coverCacheProvider: () async => coverDir,
  );

  /// 造一段带确定性内容的音频字节（不要求是合法音频：扫描只看扩展名 + 标签）。
  Uint8List fakeAudio(int length, {int seed = 0}) => Uint8List.fromList(
    List<int>.generate(length, (i) => (i * 31 + seed) & 0xFF),
  );

  group('localTrackIdFor（纯函数）', () {
    test('同样大小 + 同样头部哈希 → 同 id（移动文件后 id 不变，核心）', () {
      // 同一份内容在两个不同路径下扫描，指纹一致 → id 必须一致。
      final atOldPath = localTrackIdFor(fileSize: 4096, headHash: 'abc123');
      final atNewPath = localTrackIdFor(fileSize: 4096, headHash: 'abc123');
      expect(atNewPath, atOldPath);
      expect(atOldPath, 'local:4096:abc123');
    });

    test('大小不同 → 不同 id（尾部追加/截断能被识别）', () {
      expect(
        localTrackIdFor(fileSize: 4096, headHash: 'abc123'),
        isNot(localTrackIdFor(fileSize: 4097, headHash: 'abc123')),
      );
    });

    test('头部哈希不同 → 不同 id（同大小不同曲目能被区分）', () {
      expect(
        localTrackIdFor(fileSize: 4096, headHash: 'abc123'),
        isNot(localTrackIdFor(fileSize: 4096, headHash: 'abc124')),
      );
    });

    test('边界：0 字节文件（空哈希）仍产出可用 id', () {
      final id = localTrackIdFor(fileSize: 0, headHash: '');
      expect(id, 'local:0:');
      expect(id.startsWith('local:'), isTrue);
    });

    test('id 不含路径：非 ASCII / 超长路径不会渗进 id', () {
      // id 是纯指纹拼接，路径信息只存在于 sourceData。
      final id = localTrackIdFor(fileSize: 12, headHash: 'ff00');
      expect(id, isNot(contains('/')));
      expect(id, isNot(contains('\\')));
      expect(id, isNot(contains('音乐')));
    });
  });

  group('readHeadHash（前 64KB 采样）', () {
    test('前 64KB 相同、尾部不同 → 哈希相同（只看头部，控制 IO 代价）', () async {
      final a = File('${tempDir.path}/a.bin');
      final b = File('${tempDir.path}/b.bin');
      final head = fakeAudio(64 * 1024);
      await a.writeAsBytes(<int>[...head, 0x11, 0x22]);
      await b.writeAsBytes(<int>[...head, 0x33]);

      expect(await readHeadHash(b), await readHeadHash(a));
    });

    test('前 64KB 内任一字节不同 → 哈希不同', () async {
      final a = File('${tempDir.path}/c.bin');
      final b = File('${tempDir.path}/d.bin');
      final bytes = fakeAudio(1024);
      await a.writeAsBytes(bytes);
      final mutated = Uint8List.fromList(bytes);
      mutated[1023] = mutated[1023] ^ 0xFF; // 翻转最后一字节
      await b.writeAsBytes(mutated);

      expect(await readHeadHash(b), isNot(await readHeadHash(a)));
    });

    test('边界：空文件哈希稳定且不抛错', () async {
      final empty = File('${tempDir.path}/empty.bin');
      await empty.writeAsBytes(<int>[]);
      expect(await readHeadHash(empty), await readHeadHash(empty));
    });
  });

  group('扫描端到端：移动文件后 id 不变', () {
    test('同内容文件换目录（模拟移动/重命名音乐目录）→ id 不变、path 更新', () async {
      final oldDir = Directory('${tempDir.path}/old_album')..createSync();
      final song = File('${oldDir.path}/song.mp3');
      await song.writeAsBytes(fakeAudio(4096));

      final before = await buildSource(oldDir).scanLibrary();
      expect(before, hasLength(1));
      final oldTrack = before.single;
      expect(oldTrack.sourceData?['path'], song.path);

      // 用户把整个目录改名 / 换位置：内容一模一样，只有路径变了。
      final newDir = Directory('${tempDir.path}/new_album')..createSync();
      await song.rename('${newDir.path}/song.mp3');

      final after = await buildSource(newDir).scanLibrary(force: true);
      expect(after, hasLength(1));
      final newTrack = after.single;

      // 核心断言放在最前：路径变了但 id 必须原样保持。
      expect(newTrack.id, oldTrack.id, reason: '移动文件后稳定 id 必须不变');
      expect(newTrack.key, oldTrack.key, reason: 'key 是收藏/歌单的索引键');
      expect(newTrack.id, startsWith('local:'), reason: 'id 是内容指纹而非路径');
      expect(newTrack.sourceData?['path'], '${newDir.path}/song.mp3');
      expect(newTrack.sourceData?['path'], isNot(oldTrack.sourceData?['path']));
    });

    test('内容不同 → id 不同（指纹确实参与计算，而非退化成常量）', () async {
      final dir = Directory('${tempDir.path}/mixed')..createSync();
      await File('${dir.path}/one.mp3').writeAsBytes(fakeAudio(4096, seed: 1));
      await File('${dir.path}/two.mp3').writeAsBytes(fakeAudio(4096, seed: 2));

      final tracks = await buildSource(dir).scanLibrary();
      expect(tracks, hasLength(2));
      expect(tracks[0].id, isNot(tracks[1].id));
    });

    test('边界：0 字节文件与非 ASCII / 超长路径仍能扫描并生成指纹 id', () async {
      // 目录名含空格 / 中文，且嵌套较深（扫描深度上限 8）。
      final deep = Directory(
        <String>[
          tempDir.path,
          '音乐 目录 with spaces',
          List<String>.filled(4, 'nested_folder').join('/'),
        ].join('/'),
      )..createSync(recursive: true);
      final empty = File('${deep.path}/空文件.mp3');
      await empty.writeAsBytes(<int>[]);

      final tracks = await buildSource(tempDir).scanLibrary();
      expect(tracks, hasLength(1));
      final track = tracks.single;
      // 空文件的头部哈希就是空字节的 sha1（不是「随便什么值」）。
      expect(
        track.id,
        localTrackIdFor(
          fileSize: 0,
          headHash: crypto.sha1.convert(<int>[]).toString(),
        ),
      );
      expect(track.id, startsWith('local:0:'));
      expect(track.sourceData?['path'], empty.path);
      expect(track.sourceData?['path'], contains('音乐 目录 with spaces'));
    });
  });

  group('旧数据兼容：localFilePathOf', () {
    test('sourceData[\'path\'] 存在 → 取 path（新数据主路径）', () {
      const track = Track(
        id: 'local:4096:abc123',
        sourceId: 'local',
        title: 't',
        artist: 'a',
        sourceData: <String, dynamic>{'path': '/music/song.mp3'},
      );
      expect(localFilePathOf(track), '/music/song.mp3');
    });

    test('旧数据：id 是绝对路径、无 sourceData → 回退到 id', () {
      const track = Track(
        id: '/Users/me/Music/old.mp3',
        sourceId: 'local',
        title: 't',
        artist: 'a',
      );
      expect(localFilePathOf(track), '/Users/me/Music/old.mp3');
    });

    test('旧数据：Windows 盘符路径 id → 回退到 id', () {
      const track = Track(
        id: r'C:\Users\me\Music\old.mp3',
        sourceId: 'local',
        title: 't',
        artist: 'a',
      );
      expect(localFilePathOf(track), r'C:\Users\me\Music\old.mp3');
      expect(
        localFilePathOf(track.copyWith(id: 'D:/Music/old.mp3')),
        'D:/Music/old.mp3',
      );
    });

    test('新指纹 id 且无 sourceData → 不把指纹误当路径', () {
      const track = Track(
        id: 'local:4096:abc123',
        sourceId: 'local',
        title: 't',
        artist: 'a',
      );
      expect(localFilePathOf(track), isNull);
    });

    test('sourceData 里 path 为空串 / 非字符串 → 继续走兜底', () {
      const blank = Track(
        id: '/music/song.mp3',
        sourceId: 'local',
        title: 't',
        artist: 'a',
        sourceData: <String, dynamic>{'path': '   '},
      );
      expect(localFilePathOf(blank), '/music/song.mp3');

      const wrongType = Track(
        id: 'local:1:x',
        sourceId: 'local',
        title: 't',
        artist: 'a',
        sourceData: <String, dynamic>{'path': 42},
      );
      expect(localFilePathOf(wrongType), isNull);
    });
  });

  group('resolveStream：旧数据与新数据都能播放', () {
    test('新数据（指纹 id + sourceData path）→ 解析出真实路径', () async {
      final file = File('${tempDir.path}/new.mp3');
      await file.writeAsBytes(fakeAudio(512));
      final source = buildSource(tempDir);
      final track = (await source.scanLibrary()).single;

      final resolved = await source.resolveStream(track);
      expect(resolved.url, file.path);
      expect(resolved.isLocalFile, isTrue);
    });

    test('旧数据（id 是路径、无 sourceData）→ 回退路径仍可播放', () async {
      final file = File('${tempDir.path}/legacy.mp3');
      await file.writeAsBytes(fakeAudio(512));
      final track = Track(
        id: file.path, // 旧 id 就是绝对路径
        sourceId: 'local',
        title: 'legacy',
        artist: '未知歌手',
      );

      final resolved = await buildSource(tempDir).resolveStream(track);
      expect(resolved.url, file.path);
      expect(resolved.isLocalFile, isTrue);
    });

    test('getTrackDetail 能把旧数据补成新格式（id 升级为指纹）', () async {
      final file = File('${tempDir.path}/heal.mp3');
      await file.writeAsBytes(fakeAudio(777));
      final legacy = Track(
        id: file.path,
        sourceId: 'local',
        title: 'heal',
        artist: '未知歌手',
      );

      final healed = await buildSource(tempDir).getTrackDetail(legacy);
      expect(healed.id, startsWith('local:'));
      expect(healed.sourceData?['path'], file.path);
      // 补全后依旧能播放。
      expect((await buildSource(tempDir).resolveStream(healed)).url, file.path);
    });

    test('文件不存在（指纹 id 且路径已失效）→ 抛 UnavailableStreamException', () async {
      const track = Track(
        id: 'local:4096:abc123',
        sourceId: 'local',
        title: 'gone',
        artist: 'a',
        sourceData: <String, dynamic>{'path': '/nope/missing.mp3'},
      );
      await expectLater(
        buildSource(tempDir).resolveStream(track),
        throwsA(isA<UnavailableStreamException>()),
      );
    });
  });
}
