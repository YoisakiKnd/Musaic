import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/sources/local/local_file_source.dart';

/// 本地扫描 isolate 化验证（迭代计划 §9.3 / B13）：
/// 扫描在后台 isolate 执行，目录遍历有界，UI isolate 不接触原始字节。
void main() {
  late Directory tempDir;
  late Directory coverDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('musaic_scan_test');
    coverDir = await Directory.systemTemp.createTemp('musaic_scan_covers');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    if (coverDir.existsSync()) await coverDir.delete(recursive: true);
  });

  LocalFileSource buildSource() => LocalFileSource(
    credentialReader: () async => <String, String>{},
    directoryProvider: () async => [tempDir],
    coverCacheProvider: () async => coverDir,
  );

  test('空目录扫描返回空列表（isolate 往返）', () async {
    final tracks = await buildSource().scanLibrary();
    expect(tracks, isEmpty);
  });

  test('无标签文件退回文件名；隐藏文件与非音频跳过', () async {
    File('${tempDir.path}/song.mp3').writeAsBytesSync(List.filled(256, 0x20));
    File('${tempDir.path}/notes.txt').writeAsBytesSync([1, 2, 3]);
    final hidden = Directory('${tempDir.path}/.hidden')..createSync();
    File('${hidden.path}/secret.mp3').writeAsBytesSync([1, 2, 3]);
    final album = Directory('${tempDir.path}/album')..createSync();
    File(
      '${album.path}/01 track.flac',
    ).writeAsBytesSync(List.filled(128, 0x20));

    final tracks = await buildSource().scanLibrary();
    expect(tracks.map((t) => t.title).toSet(), {'song', '01 track'});
    expect(tracks.every((t) => t.sourceId == LocalFileSource.id), isTrue);
    expect(tracks.every((t) => t.artist == '未知歌手'), isTrue);
  });

  test('并发扫描共享同一任务；force 后重新扫描可见新文件', () async {
    final source = buildSource();
    File('${tempDir.path}/a.mp3').writeAsBytesSync(List.filled(64, 0x20));

    final both = await Future.wait([
      source.scanLibrary(),
      source.scanLibrary(),
    ]);
    expect(both[0].map((t) => t.title), both[1].map((t) => t.title));

    File('${tempDir.path}/b.mp3').writeAsBytesSync(List.filled(64, 0x20));
    final refreshed = await source.scanLibrary(force: true);
    expect(refreshed.map((t) => t.title).toSet(), {'a', 'b'});
  });

  test('深度超限与缓存目录不递归', () async {
    Directory('${tempDir.path}/build').createSync();
    File('${tempDir.path}/build/inner.mp3').writeAsBytesSync([1]);
    Directory('${tempDir.path}/ok').createSync();
    File('${tempDir.path}/ok/keep.mp3').writeAsBytesSync(List.filled(64, 0x20));

    final tracks = await buildSource().scanLibrary();
    expect(tracks.map((t) => t.title), ['keep']);
  });

  /// 回归：用户可能同时添加父目录与子目录（`/Music` 与 `/Music/Album`），
  /// 或两条配置指向同一目录，此时同一文件会被遍历多次。
  /// 不去重会让同一首歌重复出现，且 id 相同 —— 收藏与歌单以 `track.key`
  /// 为键，重复项会互相覆盖（收藏一首显示两行同时点亮）。
  test('父子目录重叠不产生重复曲目', () async {
    final sub = Directory('${tempDir.path}/album')..createSync();
    File('${sub.path}/song.mp3').writeAsBytesSync(List.filled(64, 0x20));

    final source = LocalFileSource(
      credentialReader: () async => <String, String>{},
      // 父目录 + 子目录同时配置：扫描会走到同一个文件两次
      directoryProvider: () async => [tempDir, sub],
      coverCacheProvider: () async => coverDir,
    );
    final tracks = await source.scanLibrary(force: true);

    expect(tracks, hasLength(1));
    expect(tracks.single.title, 'song');
  });

  test('重复配置同一目录不产生重复曲目', () async {
    File('${tempDir.path}/song.mp3').writeAsBytesSync(List.filled(64, 0x20));

    final source = LocalFileSource(
      credentialReader: () async => <String, String>{},
      directoryProvider: () async => [tempDir, tempDir],
      coverCacheProvider: () async => coverDir,
    );
    final tracks = await source.scanLibrary(force: true);

    expect(tracks, hasLength(1));
  });

  /// 回归：同一首歌的两份**拷贝**（不同路径、内容相同）是两个不同文件，
  /// 必须都保留 —— 内容指纹相同只说明大小与头部一致，不能据此删曲目
  /// （既有用例「force 后重新扫描可见新文件」已冻结此行为）。
  test('内容相同的不同文件都保留（不按指纹误删）', () async {
    final bytes = List.filled(128, 0x20);
    File('${tempDir.path}/a.mp3').writeAsBytesSync(bytes);
    final copy = Directory('${tempDir.path}/copy')..createSync();
    File('${copy.path}/b.mp3').writeAsBytesSync(bytes);

    final tracks = await buildSource().scanLibrary();

    expect(tracks, hasLength(2));
  });

  test('内容不同但标题相同的曲目都保留（不误删同名曲）', () async {
    File('${tempDir.path}/a/song.mp3').parent.createSync(recursive: true);
    File('${tempDir.path}/a/song.mp3').writeAsBytesSync(List.filled(128, 0x20));
    File('${tempDir.path}/b/song.mp3').parent.createSync(recursive: true);
    File('${tempDir.path}/b/song.mp3').writeAsBytesSync(List.filled(256, 0x40));

    final tracks = await buildSource().scanLibrary();

    expect(tracks, hasLength(2));
    expect(tracks.map((t) => t.id).toSet(), hasLength(2));
  });
}
