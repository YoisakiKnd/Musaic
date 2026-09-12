import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/sources/netease/netease_crypto.dart';

/// 网易云 weapi 加密（覆盖率补强：该文件此前 0%）。
///
/// 这是纯函数，且有**明确可验证的不变量**，非常适合测试：
/// - encSecKey 恒为 256 位十六进制（RSA 无填充 + 公钥模长决定）；
/// - params 可被 secretKey 逆解回原始 JSON（AES 对称）；
/// - 同样的随机源 → 同样的输出（可复现）。
///
/// 不测「与线上服务端一致」——那需要真机联网，属于 T5 真机验证范围。
void main() {
  group('encryptPayload 结构不变量', () {
    test('返回 params 与 encSecKey，且 encSecKey 恒为 256 位 hex', () {
      final result = NeteaseCrypto.encryptPayload(<String, dynamic>{
        'username': 'test',
        'password': 'x',
      });

      expect(result.params, isNotEmpty);
      expect(
        result.encSecKey.length,
        256,
        reason: 'RSA 结果长度由公钥模长固定，短于此说明 padLeft 或模数有误',
      );
      expect(
        RegExp(r'^[0-9a-f]{256}$').hasMatch(result.encSecKey),
        isTrue,
        reason: '必须是纯小写十六进制',
      );
    });

    test('不同 payload 产生不同 params', () {
      final a = NeteaseCrypto.encryptPayload(<String, dynamic>{'id': 1});
      final b = NeteaseCrypto.encryptPayload(<String, dynamic>{'id': 2});
      expect(a.params, isNot(b.params));
    });

    test('相同随机源 → 完全可复现（便于排查线上问题）', () {
      final a = NeteaseCrypto.encryptPayload(<String, dynamic>{
        'id': 1,
      }, random: Random(42));
      final b = NeteaseCrypto.encryptPayload(<String, dynamic>{
        'id': 1,
      }, random: Random(42));
      expect(a.params, b.params);
      expect(a.encSecKey, b.encSecKey);
    });

    test('空 payload 也能加密（不抛异常）', () {
      expect(
        () => NeteaseCrypto.encryptPayload(<String, dynamic>{}),
        returnsNormally,
      );
    });

    test('嵌套 / 中文 / 特殊字符 payload 不抛异常', () {
      expect(
        () => NeteaseCrypto.encryptPayload(<String, dynamic>{
          'nested': <String, dynamic>{
            'a': [1, 2, 3],
          },
          'cn': '海阔天空',
          'quote': 'he said "hi" & <tag>',
          'unicode': '🎵',
        }),
        returnsNormally,
      );
    });

    test('超长 payload 不抛异常', () {
      expect(
        () => NeteaseCrypto.encryptPayload(<String, dynamic>{
          'big': 'x' * 100000,
        }),
        returnsNormally,
      );
    });
  });

  group('加密算法可逆性（核心正确性）', () {
    // 用与实现相同的算法逆解两层，验证 key / iv / 顺序都没有写错。
    //
    // 这是本文件最重要的断言：`encryptPayload` 的输出无法直接断言「等于某个
    // 固定串」（secretKey 每次随机），因此**唯一**能验证正确性的方式就是
    // 逆解回原文。若实现里 preset key、IV 或两层顺序有误，往返必然失败。
    String? decryptTwoLayers(String paramsBase64, String secretKey) {
      const iv = '0102030405060708';
      try {
        final inner = Encrypter(
          AES(Key.fromUtf8(secretKey), mode: AESMode.cbc, padding: 'PKCS7'),
        ).decrypt64(paramsBase64, iv: IV.fromUtf8(iv));
        return Encrypter(
          AES(
            Key.fromUtf8('0CoJUm6Qyw8W8jud'),
            mode: AESMode.cbc,
            padding: 'PKCS7',
          ),
        ).decrypt64(inner, iv: IV.fromUtf8(iv));
      } catch (_) {
        return null;
      }
    }

    test('params 可逆解回原始 JSON（两层 AES 对称）', () {
      final payload = <String, dynamic>{
        'username': 'someone@example.com',
        'password': '5f4dcc3b5aa765d61d8327deb882cf99',
        'rememberLogin': true,
      };

      // 需要一个已知的 secretKey 才能逆解。实现的 secretKey 由随机源生成、
      // 不对外暴露，因此这里从 encSecKey 无法反推（RSA 单向）。
      //
      // 改为**独立复算**：用与实现完全相同的步骤加密一次，
      // 确认「实现输出 == 独立复算输出」，从而锁定算法参数。
      final result = NeteaseCrypto.encryptPayload(payload, random: Random(99));
      final recomputed = _recompute(payload: payload, random: Random(99));
      expect(
        result.params,
        recomputed.params,
        reason: '若 preset key / IV / 两层顺序有误，独立复算会不一致',
      );
      expect(result.encSecKey, recomputed.encSecKey);
    });

    test('逆解验证：复算出的 params 能被解回原文', () {
      final payload = <String, dynamic>{'id': 123, 'cn': '海阔天空'};
      final recomputed = _recompute(payload: payload, random: Random(5));

      final decoded = decryptTwoLayers(recomputed.params, recomputed.secretKey);
      expect(decoded, isNotNull, reason: '两层 AES 必须可逆');
      expect(
        jsonDecode(decoded!),
        payload,
        reason: '解回的 JSON 必须与原始 payload 完全一致',
      );
    });

    test('IV 长度必须是 16 字节（早期 10 字节 IV 会导致服务端解密失败）', () {
      // 通过「能成功往返」间接锁定：若 IV 不是 16 字节，AES-CBC 会直接抛错
      final recomputed = _recompute(
        payload: <String, dynamic>{'k': 'v'},
        random: Random(3),
      );
      expect(
        decryptTwoLayers(recomputed.params, recomputed.secretKey),
        isNotNull,
      );
    });

    test('secretKey 变化 → params 变化（说明确实用了随机密钥）', () {
      final payload = <String, dynamic>{'k': 'v'};
      final a = _recompute(payload: payload, random: Random(1));
      final b = _recompute(payload: payload, random: Random(2));
      expect(a.secretKey, isNot(b.secretKey));
      expect(a.params, isNot(b.params));
    });

    test('secretKey 为 16 位 base62 字符', () {
      final recomputed = _recompute(
        payload: <String, dynamic>{'k': 'v'},
        random: Random(11),
      );
      expect(recomputed.secretKey.length, 16);
      expect(
        RegExp(r'^[a-zA-Z0-9]{16}$').hasMatch(recomputed.secretKey),
        isTrue,
      );
    });
  });

  group('md5Hex', () {
    test('与 crypto 包结果一致', () {
      const input = 'password123';
      final expected = md5.convert(utf8.encode(input)).toString();
      expect(NeteaseCrypto.md5Hex(input), expected);
    });

    test('已知向量：空串与 "abc"', () {
      // 公开的 MD5 测试向量，用于固定算法未被意外替换
      expect(NeteaseCrypto.md5Hex(''), 'd41d8cd98f00b204e9800998ecf8427e');
      expect(NeteaseCrypto.md5Hex('abc'), '900150983cd24fb0d6963f7d28e17f72');
    });

    test('中文与 emoji 使用 UTF-8 编码', () {
      final expected = md5.convert(utf8.encode('海阔天空')).toString();
      expect(NeteaseCrypto.md5Hex('海阔天空'), expected);
      expect(NeteaseCrypto.md5Hex('海阔天空').length, 32);
    });

    test('输出恒为 32 位小写十六进制', () {
      for (final input in <String>['', 'a', 'x' * 1000, '🎵']) {
        final out = NeteaseCrypto.md5Hex(input);
        expect(out.length, 32, reason: '输入：$input');
        expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(out), isTrue);
      }
    });

    test('大小写敏感（不是同一密码）', () {
      expect(
        NeteaseCrypto.md5Hex('Password'),
        isNot(NeteaseCrypto.md5Hex('password')),
      );
    });
  });
}

/// 按**独立复算**的方式重现加密过程，用于校验实现参数。
///
/// 刻意不调用被测代码内部私有方法——那样只是「用实现验证实现」。
/// 这里用公开常量独立走一遍同样的两步 AES，任何参数写错都会暴露。
({String params, String encSecKey, String secretKey}) _recompute({
  required Map<String, dynamic> payload,
  required Random random,
}) {
  const presetKey = '0CoJUm6Qyw8W8jud';
  const iv = '0102030405060708';
  const charset =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  final secretKey =
      List<String>.generate(
        16,
        (_) => charset[random.nextInt(charset.length)],
      ).join();

  final text = jsonEncode(payload);
  final step1 =
      Encrypter(
        AES(Key.fromUtf8(presetKey), mode: AESMode.cbc, padding: 'PKCS7'),
      ).encrypt(text, iv: IV.fromUtf8(iv)).base64;
  final step2 =
      Encrypter(
        AES(Key.fromUtf8(secretKey), mode: AESMode.cbc, padding: 'PKCS7'),
      ).encrypt(step1, iv: IV.fromUtf8(iv)).base64;

  // RSA 无填充：secret 字节逆序 → 大整数 → modPow(0x10001, n) → 256 位 hex
  const modulusHex =
      '00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7'
      'b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280'
      '104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932'
      '575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b'
      '3ece0462db0a22b8e7';
  final reversedHex =
      secretKey.codeUnits.reversed
          .map((c) => c.toRadixString(16).padLeft(2, '0'))
          .join();
  final encSecKey = BigInt.parse(reversedHex, radix: 16)
      .modPow(
        BigInt.parse('010001', radix: 16),
        BigInt.parse(modulusHex, radix: 16),
      )
      .toRadixString(16)
      .padLeft(256, '0');

  return (params: step2, encSecKey: encSecKey, secretKey: secretKey);
}
