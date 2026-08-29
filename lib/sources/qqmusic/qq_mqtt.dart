/// 最小 MQTT 5.0 over WebSocket 客户端。
///
/// 只覆盖 QQ 音乐 App 扫码所需的 CONNECT / SUBSCRIBE / 收 PUBLISH / PING。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int propAuthMethod = 0x15;
const int propUserProperty = 0x26;
const int propServerKeepAlive = 0x13;
const int propServerReference = 0x1C;

const int _reasonSuccess = 0x00;
const int _reasonUseAnotherServer = 0x9C;
const int _reasonServerMoved = 0x9D;

class QqMqttPublish {
  const QqMqttPublish({
    required this.topic,
    required this.payload,
    required this.userProperties,
  });

  final String topic;
  final Uint8List payload;
  final List<(String, String)> userProperties;

  String get eventType {
    for (final (key, value) in userProperties) {
      if (key == 'type') return value;
    }
    return '';
  }
}

class QqMqttClient {
  QqMqttClient._(this._socket, this.keepAlive);

  final WebSocket _socket;
  final List<int> _buffer = <int>[];
  final List<Uint8List> _ready = <Uint8List>[];
  final List<Completer<Uint8List?>> _waiters = <Completer<Uint8List?>>[];
  StreamSubscription<dynamic>? _sub;
  int keepAlive;
  int _packetId = 1;
  bool _closed = false;

  static Future<QqMqttClient> connect({
    required String host,
    required String path,
    required String clientId,
    required int keepAlive,
    required String authMethod,
    required List<(String, String)> userProperties,
    int maxRedirects = 3,
  }) async {
    var currentPath = path;
    for (var i = 0; i <= maxRedirects; i++) {
      final client = await _connectOnce(
        host: host,
        path: currentPath,
        clientId: clientId,
        keepAlive: keepAlive,
        authMethod: authMethod,
        userProperties: userProperties,
      );
      final ack = await client._waitConnack();
      if (ack.reason == _reasonSuccess) {
        if (ack.serverKeepAlive != null) {
          client.keepAlive = ack.serverKeepAlive!;
        }
        return client;
      }
      final moved =
          ack.reason == _reasonUseAnotherServer ||
          ack.reason == _reasonServerMoved;
      if (moved && ack.serverReference != null) {
        currentPath = redirectPath(currentPath, ack.serverReference!);
        await client.close();
        continue;
      }
      await client.close();
      throw StateError(
        'MQTT CONNACK 失败：reason=0x${ack.reason.toRadixString(16)}',
      );
    }
    throw StateError('MQTT 重定向次数过多');
  }

  static Future<QqMqttClient> _connectOnce({
    required String host,
    required String path,
    required String clientId,
    required int keepAlive,
    required String authMethod,
    required List<(String, String)> userProperties,
  }) async {
    final url = 'wss://$host$path';
    final socket = await WebSocket.connect(
      url,
      protocols: const <String>['mqtt'],
      headers: <String, dynamic>{
        'Origin': 'https://y.qq.com',
        'Referer': 'https://y.qq.com/',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
      },
    ).timeout(const Duration(seconds: 20));
    final client = QqMqttClient._(socket, keepAlive);
    client._sub = socket.listen(
      (dynamic data) {
        if (data is List<int>) {
          client._onChunk(Uint8List.fromList(data));
        } else if (data is String) {
          client._onChunk(Uint8List.fromList(utf8.encode(data)));
        }
      },
      onDone: client._onSocketClosed,
      onError: (_) => client._onSocketClosed(),
    );
    socket.add(
      encodeConnect(
        clientId: clientId,
        keepAlive: keepAlive,
        authMethod: authMethod,
        userProperties: userProperties,
      ),
    );
    return client;
  }

  void _onChunk(Uint8List chunk) {
    if (_closed) return;
    _buffer.addAll(chunk);
    while (true) {
      final packet = takeOnePacket(_buffer);
      if (packet == null) break;
      final bytes = Uint8List.fromList(packet);
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(bytes);
      } else {
        _ready.add(bytes);
      }
    }
  }

  void _onSocketClosed() {
    if (_closed) return;
    _closed = true;
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.complete(null);
    }
    _waiters.clear();
  }

  Future<_Connack> _waitConnack() async {
    final packet = await _nextPacket().timeout(const Duration(seconds: 15));
    if (packet == null) throw StateError('MQTT 连接在 CONNACK 前关闭');
    final decoded = decodePacket(packet);
    if (decoded.type != 2) {
      throw StateError('期望 CONNACK，收到 type=${decoded.type}');
    }
    if (decoded.payload.length < 2) throw StateError('CONNACK 过短');
    final reason = decoded.payload[1];
    final props =
        decoded.payload.length > 2
            ? _parseConnackProps(decoded.payload.sublist(2))
            : const _Connack(reason: 0);
    return _Connack(
      reason: reason,
      serverKeepAlive: props.serverKeepAlive,
      serverReference: props.serverReference,
    );
  }

  Future<void> subscribe(
    String topic,
    List<(String, String)> userProperties,
  ) async {
    final id = _nextPacketId();
    _socket.add(encodeSubscribe(id, topic, userProperties));
    final packet = await _nextPacket().timeout(const Duration(seconds: 15));
    if (packet == null) throw StateError('MQTT 连接在 SUBACK 前关闭');
    final decoded = decodePacket(packet);
    if (decoded.type != 9) {
      throw StateError('期望 SUBACK，收到 type=${decoded.type}');
    }
    if (decoded.payload.length < 3) throw StateError('SUBACK 过短');
    final reason = decoded.payload.last;
    if (reason > 2) throw StateError('SUBACK 失败：reason=$reason');
  }

  Future<QqMqttPublish?> nextPublish() async {
    final pingSecs = (keepAlive < 2 ? 1 : keepAlive ~/ 2).clamp(5, 60);
    final pingEvery = Duration(seconds: pingSecs);
    while (!_closed) {
      Uint8List? packet;
      try {
        packet = await _nextPacket().timeout(pingEvery);
      } on TimeoutException {
        if (_closed) return null;
        _socket.add(Uint8List.fromList(const <int>[0xC0, 0x00]));
        continue;
      }
      if (packet == null) return null;
      final decoded = decodePacket(packet);
      switch (decoded.type) {
        case 3:
          return decodePublish(decoded.flags, decoded.payload);
        case 13:
          continue;
        case 14:
          return null;
        default:
          continue;
      }
    }
    return null;
  }

  int _nextPacketId() {
    final id = _packetId;
    _packetId = _packetId + 1;
    if (_packetId == 0) _packetId = 1;
    return id;
  }

  Future<Uint8List?> _nextPacket() {
    if (_ready.isNotEmpty) return Future<Uint8List?>.value(_ready.removeAt(0));
    if (_closed) return Future<Uint8List?>.value(null);
    final waiter = Completer<Uint8List?>();
    _waiters.add(waiter);
    return waiter.future;
  }

  Future<void> close() async {
    _onSocketClosed();
    await _sub?.cancel();
    try {
      await _socket.close();
    } catch (_) {}
  }
}

class _Connack {
  const _Connack({
    required this.reason,
    this.serverKeepAlive,
    this.serverReference,
  });

  final int reason;
  final int? serverKeepAlive;
  final String? serverReference;
}

class DecodedMqttPacket {
  const DecodedMqttPacket(this.type, this.flags, this.payload);
  final int type;
  final int flags;
  final Uint8List payload;
}

String redirectPath(String path, String serverReference) {
  final trimmed =
      path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final parts = trimmed.split('/');
  if (parts.isNotEmpty && parts.last.contains(':')) {
    parts[parts.length - 1] = serverReference;
    return parts.join('/');
  }
  return '$trimmed/$serverReference';
}

Uint8List encodeConnect({
  required String clientId,
  required int keepAlive,
  required String authMethod,
  required List<(String, String)> userProperties,
}) {
  final props = BytesBuilder();
  props.addByte(propAuthMethod);
  writeMqttString(props, authMethod);
  for (final (key, value) in userProperties) {
    props.addByte(propUserProperty);
    writeMqttString(props, key);
    writeMqttString(props, value);
  }
  final propBytes = props.takeBytes();

  final variable = BytesBuilder();
  writeMqttString(variable, 'MQTT');
  variable.addByte(5);
  variable.addByte(0x02);
  variable.addByte((keepAlive >> 8) & 0xFF);
  variable.addByte(keepAlive & 0xFF);
  writeVarint(variable, propBytes.length);
  variable.add(propBytes);
  writeMqttString(variable, clientId);
  final variableBytes = variable.takeBytes();

  final packet = BytesBuilder();
  packet.addByte(0x10);
  writeVarint(packet, variableBytes.length);
  packet.add(variableBytes);
  return Uint8List.fromList(packet.takeBytes());
}

Uint8List encodeSubscribe(
  int packetId,
  String topic,
  List<(String, String)> userProperties,
) {
  final props = BytesBuilder();
  for (final (key, value) in userProperties) {
    props.addByte(propUserProperty);
    writeMqttString(props, key);
    writeMqttString(props, value);
  }
  final propBytes = props.takeBytes();

  final variable = BytesBuilder();
  variable.addByte((packetId >> 8) & 0xFF);
  variable.addByte(packetId & 0xFF);
  writeVarint(variable, propBytes.length);
  variable.add(propBytes);
  writeMqttString(variable, topic);
  variable.addByte(0x00);
  final variableBytes = variable.takeBytes();

  final packet = BytesBuilder();
  packet.addByte(0x82);
  writeVarint(packet, variableBytes.length);
  packet.add(variableBytes);
  return Uint8List.fromList(packet.takeBytes());
}

DecodedMqttPacket decodePacket(Uint8List packet) {
  if (packet.isEmpty) throw StateError('空 MQTT 包');
  final type = packet[0] >> 4;
  final flags = packet[0] & 0x0F;
  final remaining = readVarint(packet.sublist(1));
  final payloadStart = 1 + remaining.size;
  if (packet.length < payloadStart + remaining.value) {
    throw StateError('MQTT 包长度不完整');
  }
  return DecodedMqttPacket(
    type,
    flags,
    packet.sublist(payloadStart, payloadStart + remaining.value),
  );
}

QqMqttPublish decodePublish(int flags, Uint8List payload) {
  if (payload.length < 2) throw StateError('PUBLISH 过短');
  final topicLen = (payload[0] << 8) | payload[1];
  if (payload.length < 2 + topicLen) throw StateError('PUBLISH topic 不完整');
  final topic = utf8.decode(payload.sublist(2, 2 + topicLen));
  var offset = 2 + topicLen;
  final qos = (flags >> 1) & 0x03;
  if (qos > 0) {
    if (payload.length < offset + 2) throw StateError('PUBLISH packet id 缺失');
    offset += 2;
  }
  final props = readVarint(payload.sublist(offset));
  offset += props.size;
  if (payload.length < offset + props.value) {
    throw StateError('PUBLISH properties 不完整');
  }
  final userProperties = parseUserProperties(
    payload.sublist(offset, offset + props.value),
  );
  offset += props.value;
  return QqMqttPublish(
    topic: topic,
    payload: payload.sublist(offset),
    userProperties: userProperties,
  );
}

_Connack _parseConnackProps(Uint8List bytes) {
  if (bytes.isEmpty) return const _Connack(reason: 0);
  final header = readVarint(bytes);
  final end = (header.size + header.value).clamp(0, bytes.length);
  final props = bytes.sublist(header.size, end);
  int? keepAlive;
  String? reference;
  var i = 0;
  while (i < props.length) {
    final id = props[i];
    i += 1;
    switch (id) {
      case propServerKeepAlive:
        if (i + 2 > props.length) throw StateError('Server Keep Alive 不完整');
        keepAlive = (props[i] << 8) | props[i + 1];
        i += 2;
      case propServerReference:
        final str = readMqttString(props.sublist(i));
        reference = str.value;
        i += str.size;
      default:
        i += skipProperty(id, props.sublist(i));
    }
  }
  return _Connack(
    reason: 0,
    serverKeepAlive: keepAlive,
    serverReference: reference,
  );
}

List<(String, String)> parseUserProperties(Uint8List bytes) {
  final out = <(String, String)>[];
  var i = 0;
  while (i < bytes.length) {
    final id = bytes[i];
    i += 1;
    if (id == propUserProperty) {
      final key = readMqttString(bytes.sublist(i));
      i += key.size;
      final value = readMqttString(bytes.sublist(i));
      i += value.size;
      out.add((key.value, value.value));
    } else {
      i += skipProperty(id, bytes.sublist(i));
    }
  }
  return out;
}

int skipProperty(int id, Uint8List rest) {
  switch (id) {
    case 0x01:
    case 0x17:
    case 0x19:
    case 0x24:
    case 0x25:
    case 0x28:
    case 0x29:
    case 0x2A:
      if (rest.isEmpty) throw StateError('属性长度不足');
      return 1;
    case 0x13:
    case 0x21:
    case 0x22:
    case 0x23:
      if (rest.length < 2) throw StateError('属性长度不足');
      return 2;
    case 0x02:
    case 0x11:
    case 0x18:
    case 0x27:
      if (rest.length < 4) throw StateError('属性长度不足');
      return 4;
    case 0x03:
    case 0x08:
    case 0x12:
    case 0x15:
    case 0x1A:
    case 0x1C:
    case 0x1F:
      return readMqttString(rest).size;
    case 0x09:
    case 0x16:
      if (rest.length < 2) throw StateError('属性长度不足');
      final len = (rest[0] << 8) | rest[1];
      if (rest.length < 2 + len) throw StateError('属性长度不足');
      return 2 + len;
    case 0x0B:
      return readVarint(rest).size;
    case 0x26:
      final key = readMqttString(rest);
      final value = readMqttString(rest.sublist(key.size));
      return key.size + value.size;
    default:
      throw StateError('未识别的 MQTT 属性：0x${id.toRadixString(16)}');
  }
}

Uint8List? takeOnePacket(List<int> buffer) {
  if (buffer.isEmpty) return null;
  late final ({int value, int size}) remaining;
  try {
    remaining = readVarint(Uint8List.fromList(buffer.sublist(1)));
  } catch (_) {
    return null;
  }
  final total = 1 + remaining.size + remaining.value;
  if (buffer.length < total) return null;
  final packet = Uint8List.fromList(buffer.sublist(0, total));
  buffer.removeRange(0, total);
  return packet;
}

void writeMqttString(BytesBuilder out, String value) {
  final bytes = utf8.encode(value);
  out.addByte((bytes.length >> 8) & 0xFF);
  out.addByte(bytes.length & 0xFF);
  out.add(bytes);
}

({String value, int size}) readMqttString(Uint8List bytes) {
  if (bytes.length < 2) throw StateError('MQTT 字符串长度缺失');
  final len = (bytes[0] << 8) | bytes[1];
  if (bytes.length < 2 + len) throw StateError('MQTT 字符串不完整');
  return (value: utf8.decode(bytes.sublist(2, 2 + len)), size: 2 + len);
}

void writeVarint(BytesBuilder out, int value) {
  var remaining = value;
  while (true) {
    var encoded = remaining % 128;
    remaining ~/= 128;
    if (remaining > 0) encoded |= 0x80;
    out.addByte(encoded);
    if (remaining == 0) break;
  }
}

({int value, int size}) readVarint(Uint8List bytes) {
  var multiplier = 1;
  var value = 0;
  for (var index = 0; index < bytes.length; index++) {
    final byte = bytes[index];
    value += (byte & 0x7F) * multiplier;
    if (byte & 0x80 == 0) return (value: value, size: index + 1);
    multiplier *= 128;
    if (index >= 3) throw StateError('MQTT remaining length 过长');
  }
  throw StateError('MQTT remaining length 不完整');
}
