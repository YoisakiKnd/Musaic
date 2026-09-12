import 'dart:convert';
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

  _waiterQueueTests();
}

String utf8TopicPrefix(Uint8List payload) {
  if (payload.length < 6) return '';
  final len = (payload[0] << 8) | payload[1];
  return String.fromCharCodes(payload.sublist(2, 2 + len));
}

/// MQTT 等待队列语义（P0 回归）。
///
/// 旧实现里 `nextPublish` 在 keepAlive 超时后只是重新 `_nextPacket()`，
/// 被 `.timeout` 放弃的 completer 仍留在 `_waiters` 队头。用户扫码后
/// 到达的 PUBLISH 会去完成这个无人监听的 completer，真正的等待者
/// 永不完成 → 扫码登录挂死到 15 分钟 deadline。
void _waiterQueueTests() {
  group('等待队列孤儿 completer（P0 回归）', () {
    test('超时后等待者被摘除，队列不残留', () async {
      final client = QqMqttClient.forTest(keepAlive: 5);
      // keepAlive=5 → ping 周期 clamp 到 5s；用短超时观察摘除行为
      expect(client.debugWaiterCount, 0);

      // 启动一次 nextPublish，它会挂起等待报文
      final pending = client.nextPublish();
      // 让出事件循环，使 _nextPacket 入队
      await Future<void>.delayed(Duration.zero);
      expect(client.debugWaiterCount, 1, reason: '应有一个等待者');

      // 不喂任何报文，等待 ping 超时后自动摘除并重试
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(
        client.debugWaiterCount,
        lessThanOrEqualTo(1),
        reason: '超时后不得累积多个孤儿等待者',
      );

      client.debugClose();
      await pending;
      expect(client.debugWaiterCount, 0);
    });

    test('超时后到达的 PUBLISH 不会被孤儿吞掉', () async {
      final client = QqMqttClient.forTest(keepAlive: 5);
      final pending = client.nextPublish();
      await Future<void>.delayed(Duration.zero);
      expect(client.debugWaiterCount, 1);

      // 等过一轮 ping 超时（孤儿若不摘除会滞留队头）
      await Future<void>.delayed(const Duration(seconds: 6));

      // 此刻投递一个合法 PUBLISH：必须被真正的等待者收到
      final publish = _encodeTestPublish('cookies');
      client.debugFeed(publish);

      final result = await pending.timeout(const Duration(seconds: 2));
      expect(result, isNotNull, reason: 'PUBLISH 被孤儿 completer 吞掉会导致扫码登录挂死');
      expect(result!.eventType, 'cookies');
      client.debugClose();
    });

    test('连接关闭唤醒所有等待者', () async {
      final client = QqMqttClient.forTest(keepAlive: 5);
      final pending = client.nextPublish();
      await Future<void>.delayed(Duration.zero);

      client.debugClose();
      expect(await pending, isNull);
      expect(client.debugWaiterCount, 0);
    });

    test('无等待者时到达的报文进入缓冲队列', () {
      final client = QqMqttClient.forTest(keepAlive: 5);
      client.debugFeed(_encodeTestPublish('scanned'));
      expect(client.debugReadyCount, 1, reason: '无人等待时应缓冲而非丢弃');
    });
  });
}

/// 构造一个合法的 MQTT 5 PUBLISH 报文（topic + 属性 + 载荷）。
Uint8List _encodeTestPublish(String eventType) {
  final topic = utf8.encode('test/topic');
  final payload = utf8.encode('{"ok":true}');

  // 属性：一个 user property (0x26) = key/value
  final key = utf8.encode('type');
  final value = utf8.encode(eventType);
  final props =
      BytesBuilder()
        ..addByte(0x26)
        ..addByte((key.length >> 8) & 0xFF)
        ..addByte(key.length & 0xFF)
        ..add(key)
        ..addByte((value.length >> 8) & 0xFF)
        ..addByte(value.length & 0xFF)
        ..add(value);
  final propBytes = props.takeBytes();

  // 属性段本身以 varint 长度开头（MQTT 5 规范）
  final body =
      BytesBuilder()
        ..addByte((topic.length >> 8) & 0xFF)
        ..addByte(topic.length & 0xFF)
        ..add(topic)
        ..addByte(propBytes.length)
        ..add(propBytes)
        ..add(payload);
  final bodyBytes = body.takeBytes();

  final packet =
      BytesBuilder()
        ..addByte(0x30) // PUBLISH, QoS 0
        ..addByte(bodyBytes.length) // 测试载荷 < 128 字节，单字节剩余长度
        ..add(bodyBytes);
  return packet.takeBytes();
}
