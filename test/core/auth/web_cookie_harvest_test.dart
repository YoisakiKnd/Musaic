import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/auth/web_cookie_harvest.dart';

void main() {
  test('合并 document.cookie 并识别 YouTube 登录 Cookie', () {
    final cookies = <String, String>{};
    mergeCookieHeader(
      cookies,
      '"SID=sid-value; __Secure-1PSID=psid-value; __Secure-3PAPISID=sapi-value"',
    );
    expect(cookies['SID'], 'sid-value');
    expect(hasYoutubeLoginCookies(cookies), isTrue);
  });

  test('缺 SAPISID/PSID 不算已登录', () {
    expect(hasYoutubeLoginCookies({'VISITOR_INFO1_LIVE': 'x'}), isFalse);
  });

  test('后写入的同名 Cookie 不会覆盖 YouTube 域已有值', () {
    final cookies = <String, String>{};
    mergeCookiePair(cookies, 'SAPISID', 'youtube-sapi');
    mergeCookiePair(cookies, 'SAPISID', 'google-sapi');
    expect(cookies['SAPISID'], 'youtube-sapi');
  });

  test('Cookie 名大小写不影响登录判定', () {
    expect(
      hasYoutubeLoginCookies({'sapisid': 'sapi', '__secure-3psid': 'psid'}),
      isTrue,
    );
  });

  test('Cookie 只允许登录能力声明的域名及其子域名', () {
    final origins = [
      Uri.parse('https://music.youtube.com'),
      Uri.parse('https://accounts.google.com'),
    ];

    expect(isCookieHostAllowed('music.youtube.com', origins), isTrue);
    expect(isCookieHostAllowed('login.music.youtube.com', origins), isTrue);
    expect(isCookieHostAllowed('www.youtube.com', origins), isFalse);
    expect(isCookieHostAllowed('accounts.google.com', origins), isTrue);
    expect(isCookieHostAllowed('example.com', origins), isFalse);
  });
  test('dynamic Cookie.value 也能写入', () {
    final cookies = <String, String>{};
    mergeCookiePair(cookies, ' SAPISID ', Object());
    expect(cookies.containsKey('SAPISID'), isTrue);
    expect(cookies['SAPISID'], isNot(equals('null')));
  });
}
