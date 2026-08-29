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
}
