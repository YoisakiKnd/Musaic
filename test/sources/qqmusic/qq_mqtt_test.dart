import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/sources/qqmusic/qq_mqtt.dart';

void main() {
  group('MQTT remaining length', () {
    test('write/read 单字节往返', () {
      final out = BytesBuilder();
      writeVarint(out, 127);
      final bytes = Uint8List.fromList(out.takeBytes());
      final decoded = readVarint(bytes);
      expect(decoded.value, 127);
      expect(decoded.size, 1);
    });

    test('write/read 多字节往返', () {
      final out = BytesBuilder();
      writeVarint(out, 321);
      final bytes = Uint8List.fromList(out.takeBytes());
      final decoded = readVarint(bytes);
      expect(decoded.value, 321);
      expect(decoded.size, 2);
    });
  });

  test('encodeConnect 是 MQTT 5 CONNECT', () {
    final packet = encodeConnect(
      clientId: 'musaic-test',
      keepAlive: 45,
      authMethod: 'pass',
      userProperties: const <(String, String)>[
        ('tmeAppID', 'qqmusic'),
        ('business', 'management'),
      ],
    );
    expect(packet.first, 0x10);
    final decoded = decodePacket(packet);
    expect(decoded.type, 1);
    expect(utf8TopicPrefix(decoded.payload), 'MQTT');
  });

  test('CONNACK 重定向拼接 path', () {
    expect(
      redirectPath('/ws/handshake', 'node-a:123'),
      '/ws/handshake/node-a:123',
    );
    expect(
      redirectPath('/ws/handshake/old:1', 'node-b:2'),
      '/ws/handshake/node-b:2',
    );
  });

  test('takeOnePacket 按 remaining length 切包', () {
    final connect = encodeConnect(
      clientId: 'a',
      keepAlive: 10,
      authMethod: 'pass',
      userProperties: const <(String, String)>[],
    );
    final buffer = <int>[...connect, 0x10];
    final first = takeOnePacket(buffer);
    expect(first, isNotNull);
    expect(first!.length, connect.length);
    expect(buffer, <int>[0x10]);
    expect(takeOnePacket(buffer), isNull);
  });
}

String utf8TopicPrefix(Uint8List payload) {
  if (payload.length < 6) return '';
  final len = (payload[0] << 8) | payload[1];
  return String.fromCharCodes(payload.sublist(2, 2 + len));
}
