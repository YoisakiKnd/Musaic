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

  _sessionFilterTests();
}

/// Cookie 最小权限裁剪（P1 安全回归）。
///
/// 采集阶段需要读 accounts.google.com 才能拿到 SAPISID，但该域下
/// 混有 Google 账号的其它会话 Cookie，直接落盘会超出应用所需权限。
void _sessionFilterTests() {
  group('filterYoutubeSessionCookies', () {
    test('只保留白名单键，丢弃无关 Google 账号 Cookie', () {
      final raw = <String, String>{
        'SAPISID': 'sapisid-value',
        '__Secure-1PSID': 'psid-value',
        'LOGIN_INFO': 'login-info',
        // 以下均不属于本应用所需，必须被丢弃
        'NID': 'google-nid',
        'LSID': 'google-lsid',
        'ACCOUNT_CHOOSER': 'chooser',
        'GAPS': 'gaps',
        '1P_JAR': 'jar',
        'AEC': 'aec',
        'SEARCH_SAMESITE': 'samesite',
      };

      final filtered = filterYoutubeSessionCookies(raw);

      expect(filtered['SAPISID'], 'sapisid-value');
      expect(filtered['__Secure-1PSID'], 'psid-value');
      expect(filtered['LOGIN_INFO'], 'login-info');
      expect(filtered.containsKey('NID'), isFalse);
      expect(filtered.containsKey('LSID'), isFalse);
      expect(filtered.containsKey('ACCOUNT_CHOOSER'), isFalse);
      expect(filtered.containsKey('GAPS'), isFalse);
      expect(filtered.containsKey('1P_JAR'), isFalse);
      expect(filtered.containsKey('AEC'), isFalse);
      expect(filtered.containsKey('SEARCH_SAMESITE'), isFalse);
      expect(filtered, hasLength(3));
    });

    test('键名匹配不区分大小写', () {
      final filtered = filterYoutubeSessionCookies(<String, String>{
        'sapisid': 'lower',
        'Login_Info': 'mixed',
        'unrelated': 'x',
      });
      expect(filtered['sapisid'], 'lower');
      expect(filtered['Login_Info'], 'mixed');
      expect(filtered.containsKey('unrelated'), isFalse);
    });

    test('空输入返回空 Map', () {
      expect(filterYoutubeSessionCookies(<String, String>{}), isEmpty);
    });

    test('裁剪后仍满足登录态判定（hasYoutubeLoginCookies）', () {
      final raw = <String, String>{
        'SAPISID': 'a',
        '__Secure-1PSID': 'b',
        'NID': 'noise',
      };
      expect(hasYoutubeLoginCookies(filterYoutubeSessionCookies(raw)), isTrue);
      expect(
        hasYoutubeLoginCookies(
          filterYoutubeSessionCookies(<String, String>{'NID': 'x'}),
        ),
        isFalse,
      );
    });
  });
}
