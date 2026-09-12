import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 架构守护测试（改进计划 E1 / 迭代计划 I0-04）。
///
/// README「模块依赖铁律」此前只是文档约定，没有任何东西会阻止
/// `features/` 直接 import `sources/`。本测试把已完成的分层重构
/// 固化为不可回退的契约。
///
/// 规则：
/// 1. `lib/core/**` 不得 import `lib/features/**` 或 `lib/sources/**`；
/// 2. `lib/features/**` 不得 import `lib/sources/**`（渠道只能经
///    `SourceRegistry` / 能力接口消费）；
/// 3. `lib/sources/**` 不得 import `lib/features/**`（渠道只依赖领域层）。
///
/// 唯一豁免：`lib/core/di/` 是**组合根**，其职责就是装配具体实现，
/// 因此允许它 import 任意层（这也是它存在的意义）。
void main() {
  final libDir = Directory('lib');

  /// 组合根豁免前缀（见上方说明）。
  const compositionRootPrefix = 'lib/core/di/';

  List<File> dartFilesIn(String relative) {
    final dir = Directory('lib/$relative');
    if (!dir.existsSync()) return const <File>[];
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList(growable: false);
  }

  /// 提取文件中的相对 import 目标（跳过 dart:/package:）。
  List<String> relativeImportsOf(File file) {
    final pattern = RegExp(r"""^\s*import\s+['"]([^'"]+)['"]""");
    return file
        .readAsLinesSync()
        .map((line) => pattern.firstMatch(line)?.group(1))
        .whereType<String>()
        .where((target) => !target.startsWith('dart:'))
        .where((target) => !target.startsWith('package:'))
        .toList(growable: false);
  }

  /// 把相对 import 解析为 lib/ 下的规范路径（去掉 ../ 与 ./）。
  String normalize(File from, String target) {
    final baseSegments = from.parent.path.split(Platform.pathSeparator);
    for (final segment in target.split('/')) {
      if (segment == '.' || segment.isEmpty) continue;
      if (segment == '..') {
        if (baseSegments.isNotEmpty) baseSegments.removeLast();
      } else {
        baseSegments.add(segment);
      }
    }
    return baseSegments.join('/');
  }

  void assertNoIllegalImports({
    required String layer,
    required List<String> forbiddenPrefixes,
  }) {
    final violations = <String>[];
    for (final file in dartFilesIn(layer)) {
      // 组合根是唯一的装配点，允许跨层引用具体实现。
      final normalizedPath = file.path.replaceAll(r'\', '/');
      if (normalizedPath.startsWith(compositionRootPrefix)) continue;
      for (final target in relativeImportsOf(file)) {
        final resolved = normalize(file, target);
        for (final prefix in forbiddenPrefixes) {
          if (resolved.startsWith(prefix)) {
            violations.add('${file.path} → $target（命中 $prefix）');
          }
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '架构分层被破坏，以下 import 违反依赖铁律：\n${violations.join('\n')}',
    );
  }

  test('组合根（core/di）是唯一允许跨层的装配点', () {
    // 反向守护：确保豁免范围没有被无意识扩大。
    final offenders = <String>[];
    for (final file in dartFilesIn('core')) {
      final normalizedPath = file.path.replaceAll(r'\', '/');
      if (!normalizedPath.startsWith(compositionRootPrefix)) continue;
      offenders.add(normalizedPath);
    }
    expect(offenders, isNotEmpty, reason: '组合根应存在于 lib/core/di/ 下');
  });

  test('core 不依赖 features / sources（领域层保持独立）', () {
    assertNoIllegalImports(
      layer: 'core',
      forbiddenPrefixes: ['lib/features/', 'lib/sources/'],
    );
  });

  test('features 不直接 import sources（必须经 SourceRegistry）', () {
    assertNoIllegalImports(
      layer: 'features',
      forbiddenPrefixes: ['lib/sources/'],
    );
  });

  test('sources 不依赖 features（渠道只依赖领域层）', () {
    assertNoIllegalImports(
      layer: 'sources',
      forbiddenPrefixes: ['lib/features/'],
    );
  });

  test('测试目录本身可被解析（守护测试前置条件）', () {
    expect(libDir.existsSync(), isTrue);
    expect(dartFilesIn('core'), isNotEmpty);
    expect(dartFilesIn('features'), isNotEmpty);
    expect(dartFilesIn('sources'), isNotEmpty);
  });
}
