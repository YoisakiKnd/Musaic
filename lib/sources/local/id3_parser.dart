import 'dart:convert';
import 'dart:typed_data';

/// ID3 标签解析结果。
class Id3Tags {
  String? title;
  String? artist;
  String? album;

  /// 内嵌歌词（USLT），可能为纯文本或带时间戳的 LRC。
  String? lyrics;

  /// 内嵌封面字节与 MIME（APIC pictureType == 3 优先）。
  Uint8List? coverBytes;
  String? coverMime;
}

/// 轻量 ID3 解析器：支持 ID3v2.2 / v2.3 / v2.4 与 ID3v1 兜底。
///
/// 仅做字节级转换，不接触文件系统（便于单元测试）。
/// 提取字段：TIT2(TT2)/TPE1(TP1)/TALB(TAL)/USLT(ULT)/APIC(PIC)。
abstract final class Id3Parser {
  static const int _v2HeaderSize = 10;

  /// 从音频文件头部字节解析标签；无 ID3 返回 null。
  static Id3Tags? parse(Uint8List bytes) {
    if (bytes.length < _v2HeaderSize) return _tryParseV1(bytes);
    if (_ascii(bytes, 0, 3) != 'ID3') return _tryParseV1(bytes);

    final major = bytes[3];
    final flags = bytes[5];
    final size = _synchsafeInt(bytes, 6); // 不含头部

    var end = _v2HeaderSize + size;
    if (end > bytes.length) end = bytes.length;
    Uint8List payload = bytes.sublist(_v2HeaderSize, end);

    // 反去同步（unsynchronisation）：FF 00 → FF
    if (flags & 0x80 != 0) {
      payload = _deUnsynchronise(payload);
    }

    var offset = 0;
    // 扩展头
    if (flags & 0x40 != 0 && payload.length >= 4) {
      final extSize = major >= 4
          ? _synchsafeInt(payload, 0)
          : _uint32(payload, 0) + 4;
      offset += extSize;
    }

    final tags = Id3Tags();
    final frameIdLength = major <= 2 ? 3 : 4;

    while (offset + frameIdLength + (major <= 2 ? 3 : 6) <= payload.length) {
      final frameId = _ascii(payload, offset, frameIdLength);
      if (frameId.isEmpty || !RegExp(r'^[A-Z0-9]+$').hasMatch(frameId)) {
        break; // padding 区
      }
      var headerLen = 0;
      int frameSize;
      if (major <= 2) {
        frameSize = (payload[offset + 3] << 16) |
            (payload[offset + 4] << 8) |
            payload[offset + 5];
        headerLen = 6;
      } else {
        frameSize = major >= 4
            ? _synchsafeInt(payload, offset + 4)
            : _uint32(payload, offset + 4);
        headerLen = 10;
      }
      if (frameSize <= 0 ||
          offset + headerLen + frameSize > payload.length) {
        break;
      }
      final content =
          payload.sublist(offset + headerLen, offset + headerLen + frameSize);

      switch (frameId) {
        case 'TIT2' || 'TT2':
          tags.title ??= _decodeTextFrame(content);
        case 'TPE1' || 'TP1':
          tags.artist ??= _decodeTextFrame(content);
        case 'TALB' || 'TAL':
          tags.album ??= _decodeTextFrame(content);
        case 'USLT' || 'ULT':
          tags.lyrics ??= _decodeUnsyncLyrics(content);
        case 'APIC' || 'PIC':
          _decodePicture(content, major, tags);
      }
      offset += headerLen + frameSize;
    }

    final hasAny = tags.title != null ||
        tags.artist != null ||
        tags.album != null ||
        tags.coverBytes != null ||
        tags.lyrics != null;
    return hasAny ? tags : _tryParseV1(bytes);
  }

  // ---------- 文本帧 ----------

  static String? _decodeTextFrame(Uint8List content) {
    if (content.isEmpty) return null;
    final text = _decodeStringByEncoding(
      content.sublist(1),
      encodingByte: content[0],
      stopAtTerminator: true,
    );
    return text == null || text.isEmpty ? null : text;
  }

  /// USLT: [encoding][lang:3][descriptor:terminated][text]
  static String? _decodeUnsyncLyrics(Uint8List content) {
    if (content.length < 5) return null;
    final encodingByte = content[0];
    var offset = 4; // encoding + lang
    final termWidth = _terminatorWidth(encodingByte);
    while (offset + termWidth <= content.length) {
      final isTerminator = termWidth == 1
          ? content[offset] == 0
          : content[offset] == 0 && content[offset + 1] == 0;
      if (isTerminator) {
        offset += termWidth;
        break;
      }
      offset += termWidth;
    }
    final text = _decodeStringByEncoding(
      content.sublist(offset.clamp(0, content.length)),
      encodingByte: encodingByte,
    );
    return text == null || text.trim().isEmpty ? null : text;
  }

  /// APIC(v2.3+): [encoding][mime\0][pictType][description\0][data]
  /// PIC(v2.2):    [encoding][format:3][pictType][description\0][data]
  static void _decodePicture(
    Uint8List content,
    int major,
    Id3Tags tags,
  ) {
    try {
      if (content.isEmpty) return;
      final encodingByte = content[0];
      var offset = 1;
      String mime;
      if (major <= 2) {
        if (content.length < 4 + 1) return;
        mime = _ascii(content, offset, 3).toLowerCase();
        offset += 3;
      } else {
        final zeroIndex = content.indexOf(0, offset);
        if (zeroIndex < 0) return;
        mime = _ascii(content, offset, zeroIndex - offset).toLowerCase();
        offset = zeroIndex + 1;
      }
      if (offset >= content.length) return;
      offset += 1; // picture type

      final termWidth = _terminatorWidth(encodingByte);
      while (offset + termWidth <= content.length) {
        final terminated = termWidth == 1
            ? content[offset] == 0
            : content[offset] == 0 && content[offset + 1] == 0;
        if (terminated) {
          offset += termWidth;
          break;
        }
        offset += termWidth;
      }
      if (offset >= content.length) return;

      final data = content.sublist(offset);
      // 已跳过 pictType 字节；默认接受首个封面
      if (data.isNotEmpty &&
          tags.coverBytes == null &&
          (mime.startsWith('image/') || mime == 'jpg' || mime == 'png')) {
        tags.coverBytes = data;
        tags.coverMime = mime.contains('png') ? 'image/png' : 'image/jpeg';
      }
    } catch (_) {
      // 封面解析失败不影响其余标签
    }
  }

  // ---------- 编码 ----------

  static int _terminatorWidth(int encodingByte) =>
      encodingByte == 1 || encodingByte == 2 ? 2 : 1;

  static String? _decodeStringByEncoding(
    Uint8List bytes, {
    required int encodingByte,
    bool stopAtTerminator = false,
  }) {
    try {
      switch (encodingByte) {
        case 0: // ISO-8859-1
          return _stop(_latin1(bytes), stopAtTerminator, false);
        case 1: // UTF-16 with BOM
          if (bytes.length < 2) return '';
          final littleEndian = bytes[0] == 0xFF && bytes[1] == 0xFE;
          final body = bytes.sublist(2);
          return _stop(
            _utf16(body, littleEndian),
            stopAtTerminator,
            true,
          );
        case 2: // UTF-16BE
          return _stop(_utf16(bytes, false), stopAtTerminator, true);
        case 3: // UTF-8
        default:
          return _stop(utf8.decode(bytes, allowMalformed: true),
              stopAtTerminator, false);
      }
    } catch (_) {
      return null;
    }
  }

  static String _stop(String s, bool enabled, bool wide) {
    if (!enabled) return _stripNull(s);
    final terminator = wide ? '\u0000\u0000' : '\u0000';
    final index = s.indexOf(terminator);
    final value = index >= 0 ? s.substring(0, index) : s;
    return _stripNull(value);
  }

  static String _stripNull(String s) => s.replaceAll('\u0000', '').trim();

  static String _latin1(Uint8List bytes) {
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.writeCharCode(b);
    }
    return buffer.toString();
  }

  static String _utf16(Uint8List bytes, bool littleEndian) {
    final buffer = StringBuffer();
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final unit = littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1];
      buffer.writeCharCode(unit);
    }
    return buffer.toString();
  }

  // ---------- 头部工具 ----------

  static int _synchsafeInt(Uint8List b, int offset) =>
      (b[offset] & 0x7F) << 21 |
      (b[offset + 1] & 0x7F) << 14 |
      (b[offset + 2] & 0x7F) << 7 |
      (b[offset + 3] & 0x7F);

  static int _uint32(Uint8List b, int offset) =>
      (b[offset] << 24) |
      (b[offset + 1] << 16) |
      (b[offset + 2] << 8) |
      b[offset + 3];

  static String _ascii(Uint8List b, int start, int length) {
    if (start < 0 || start + length > b.length) return '';
    return String.fromCharCodes(b.sublist(start, start + length));
  }

  static Uint8List _deUnsynchronise(Uint8List input) {
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < input.length; i++) {
      out.addByte(input[i]);
      if (input[i] == 0xFF &&
          i + 1 < input.length &&
          input[i + 1] == 0x00) {
        i++;
      }
    }
    return out.toBytes();
  }

  // ---------- ID3v1 兜底 ----------

  static Id3Tags? _tryParseV1(Uint8List bytes) {
    if (bytes.length < 128) return null;
    final tail = bytes.sublist(bytes.length - 128);
    if (_ascii(tail, 0, 3) != 'TAG') return null;
    String field(int start, int len) =>
        _stripNull(latin1.decode(tail.sublist(start, start + len),
            allowInvalid: true));
    final tags = Id3Tags()
      ..title = field(3, 30)
      ..artist = field(33, 30)
      ..album = field(63, 30);
    final hasAny = (tags.title?.isNotEmpty ?? false) ||
        (tags.artist?.isNotEmpty ?? false);
    if (!hasAny) return null;
    if (tags.title?.isEmpty ?? false) tags.title = null;
    if (tags.artist?.isEmpty ?? false) tags.artist = null;
    if (tags.album?.isEmpty ?? false) tags.album = null;
    return tags;
  }
}
