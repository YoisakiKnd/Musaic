import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';

/// 网易云 weapi 请求加密（登录等敏感接口使用）。
///
/// 算法（对照 NeteaseCloudMusicApi 参考实现校准）：
/// 1. 生成 16 位随机 secretKey（base62 字符集）；
/// 2. params = AES-CBC-PKCS7(json, key:'0CoJUm6Qyw8W8jud', iv:'0102030405060708')
///    → base64，再用 secretKey 同 iv 二次加密 → base64；
/// 3. encSecKey = RSA 无填充(secretKey 字节逆序, e=010001, n=网易公钥)
///    → 256 位十六进制。
abstract final class NeteaseCrypto {
  static const String _presetKey = '0CoJUm6Qyw8W8jud';

  /// 注意：必须为 16 字节 ASCII；早期流传的 '0102030405' 短 IV
  /// 会使服务端 CBC 首块解密失败并返回空响应体。
  static const String _iv = '0102030405060708';
  static const String _charset =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  /// 网易云公开 RSA 公钥（N，十六进制）。
  static const String _publicKeyModulus =
      '00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7'
      'b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280'
      '104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932'
      '575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b'
      '3ece0462db0a22b8e7';

  /// IV 即 16 字节 ASCII 原文，无零填充。
  static IV get _iv16 => IV.fromUtf8(_iv);

  static final Encrypter _presetEncrypter = Encrypter(
    AES(
      Key.fromUtf8(_presetKey),
      mode: AESMode.cbc,
      padding: 'PKCS7',
    ),
  );

  /// 生成 weapi 请求体参数。
  static ({String params, String encSecKey}) encryptPayload(
    Map<String, dynamic> payload, {
    Random? random,
  }) {
    final text = jsonEncode(payload);
    final secretKey = _randomSecretKey(random ?? Random.secure());

    final step1 = _presetEncrypter
        .encrypt(text, iv: _iv16)
        .base64;
    final step2 = Encrypter(
      AES(
        Key.fromUtf8(secretKey),
        mode: AESMode.cbc,
        padding: 'PKCS7',
      ),
    ).encrypt(step1, iv: _iv16).base64;

    return (params: step2, encSecKey: _rsaNoPadHex(secretKey));
  }

  /// 密码 MD5 十六进制（网易云登录要求传 MD5）。
  static String md5Hex(String input) => md5.convert(utf8.encode(input)).toString();

  static String _randomSecretKey(Random random) => List.generate(
        16,
        (_) => _charset[random.nextInt(_charset.length)],
      ).join();

  /// RSA 无填充：secret 字节逆序 → 大整数 → modPow(e, n) → 256 位 hex。
  static String _rsaNoPadHex(String secret) {
    final reversed = secret.codeUnits.reversed.toList();
    final hexOfReversed = reversed
        .map((c) => c.toRadixString(16).padLeft(2, '0'))
        .join();
    final message = BigInt.parse(hexOfReversed, radix: 16);
    final exponent = BigInt.parse('010001', radix: 16);
    final modulus = BigInt.parse(_publicKeyModulus, radix: 16);
    return message.modPow(exponent, modulus).toRadixString(16).padLeft(
          256,
          '0',
        );
  }
}
