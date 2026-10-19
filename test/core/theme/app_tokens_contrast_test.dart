import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musaic/core/theme/app_tokens.dart';

/// 品牌粉按钮上一律用白字（与各页面手动指定的白色前景一致）。
///
/// 曾出现：primary 覆盖为品牌粉，onPrimary 却沿用 fromSeed 生成的深色调，
/// 深色模式下实心按钮是「粉底深红字」（首页「扫描本地音乐」实测）。
/// 按 WCAG 公式深红字的对比度也过 3:1，但截图里明显发糊，
/// 所以这里固化的是「白字」这一约定，再附带对比度下限。
void main() {
  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  for (final (name, theme) in [
    ('深色', AppTokens.darkTheme),
    ('浅色', AppTokens.lightTheme),
    ('OLED', AppTokens.oledTheme),
  ]) {
    test('$name主题：品牌粉上是白字，且对比度 ≥ 3', () {
      final scheme = theme.colorScheme;
      expect(scheme.onPrimary.computeLuminance(), greaterThan(0.9));
      expect(scheme.onSecondary.computeLuminance(), greaterThan(0.9));
      expect(
        contrast(scheme.primary, scheme.onPrimary),
        greaterThanOrEqualTo(3),
      );
    });
  }
}
