import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/sources/local/id3_parser.dart';

BytesBuilder _frame23(String id, List<int> payload) {
  final b = BytesBuilder();
  b.add(utf8.encode(id));
  final size = payload.length;
  b.add([
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
  ]);
  b.add([0x00, 0x00]); // flags
  b.add(payload);
  return b;
}

BytesBuilder _textFrame(String id, String text) {
  final payload = <int>[0x03, ...utf8.encode(text)]; // 编码字节 + UTF-8 文本
  return _frame23(id, payload);
}

Uint8List _synthV23({
  String? title,
  String? artist,
  String? album,
  String? lyrics,
  Uint8List? cover,
}) {
  final frames = BytesBuilder();
  if (title != null) frames.add(_textFrame('TIT2', title).toBytes());
  if (artist != null) frames.add(_textFrame('TPE1', artist).toBytes());
  if (album != null) frames.add(_textFrame('TALB', album).toBytes());
  if (lyrics != null) {
    final payload = <int>[
      0x03,
      ...ascii.encode('eng'),
      0x00, // 描述符终止
      ...utf8.encode(lyrics),
    ];
    frames.add(_frame23('USLT', payload).toBytes());
  }
  if (cover != null) {
    final payload = <int>[
      0x03,
      ...ascii.encode('image/jpeg'),
      0x00, // mime 终止
      0x03, // front cover
      0x00, // 空描述符终止
      ...cover,
    ];
    frames.add(_frame23('APIC', payload).toBytes());
  }

  final body = frames.toBytes();
  // v2.3 尺寸为普通 uint32
  final n = body.length;
  final header = [
    0x49, 0x44, 0x33, // "ID3"
    0x03, 0x00, // 版本 2.3
    0x00, // flags
    (n >> 24) & 0xFF,
    (n >> 16) & 0xFF,
    (n >> 8) & 0xFF,
    n & 0xFF,
  ];
  return Uint8List.fromList([...header, ...body]);
}

Uint8List _synthV1({required String title, required String artist}) {
  List<int> field(String s) {
    final bytes = ascii.encode(s);
    assert(bytes.length <= 30);
    return [...bytes, ...List.filled(30 - bytes.length, 0x20)];
  }

  final tail = <int>[
    ...ascii.encode('TAG'),
    ...field(title),
    ...field(artist),
    ...field(''), // 专辑
    ...List.filled(4, 0x20), // 年份
    ...List.filled(28, 0x00), // 注释
    0x00, // 零字节
    0x01, // 音轨
    0xFF, // 流派
  ];
  assert(tail.length == 128);
  return Uint8List.fromList([...List.filled(64, 0xAA), ...tail]);
}

void main() {
  group('ID3v2.3', () {
    test('解析标题/歌手/专辑', () {
      final bytes =
          _synthV23(title: '夜曲', artist: '周杰伦', album: '十一月的萧邦');
      final tags = Id3Parser.parse(bytes);
      expect(tags, isNotNull);
      expect(tags!.title, '夜曲');
      expect(tags.artist, '周杰伦');
      expect(tags.album, '十一月的萧邦');
    });

    test('解析 USLT 内嵌歌词', () {
      final bytes = _synthV23(lyrics: '[00:01.00]歌词内容');
      final tags = Id3Parser.parse(bytes);
      expect(tags!.lyrics, contains('[00:01.00]'));
    });

    test('解析 APIC 内嵌封面（JPEG）', () {
      final fakeJpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
      final bytes = _synthV23(cover: fakeJpeg);
      final tags = Id3Parser.parse(bytes);
      expect(tags!.coverBytes, isNotNull);
      expect(tags.coverMime, 'image/jpeg');
      expect(tags.coverBytes, hasLength(fakeJpeg.length));
    });

    test('UTF-16 BOM 编码的文本帧', () {
      const text = '海阔天空';
      // 编码字节(UTF-16 w/ BOM) + BOM + 双字节数据
      final payload = List<int>.of(const [0x01, 0xFF, 0xFE]);
      for (final unit in text.codeUnits) {
        payload.addAll([unit & 0xFF, (unit >> 8) & 0xFF]);
      }
      final frame = BytesBuilder();
      frame.add(utf8.encode('TIT2'));
      final size = payload.length;
      frame.add([
        (size >> 24) & 0xFF,
        (size >> 16) & 0xFF,
        (size >> 8) & 0xFF,
        size & 0xFF,
        0x00,
        0x00,
      ]);
      frame.add(payload);
      final body = frame.toBytes();
      final header = [0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0, 0, 0, body.length];
      final tags =
          Id3Parser.parse(Uint8List.fromList([...header, ...body]));
      expect(tags!.title, text);
    });
  });

  test('ID3v1 兜底：无 v2 头时读取尾部标签', () {
    final bytes = _synthV1(title: 'Beyond Song', artist: 'Wong Ka Kui');
    final tags = Id3Parser.parse(bytes);
    expect(tags, isNotNull);
    expect(tags!.title, 'Beyond Song');
    expect(tags.artist, 'Wong Ka Kui');
  });

  test('非 ID3 数据且无 v1 标签 → null', () {
    final noise = Uint8List.fromList(List.filled(256, 0x12));
    expect(Id3Parser.parse(noise), isNull);
  });

  test('过短输入安全返回', () {
    expect(Id3Parser.parse(Uint8List.fromList([0x49, 0x44])), isNull);
  });
}
