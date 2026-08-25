import 'music_source.dart';

/// 渠道注册中心（Master Plan §4 / §5.3）。
///
/// UI 与应用层只依赖本类解析渠道；注册顺序即 UI 展示顺序。
class SourceRegistry {
  final Map<String, MusicSource> _sources = <String, MusicSource>{};

  /// 注册渠道；同 id 后注册者覆盖先注册者（便于测试替换）。
  void register(MusicSource source) {
    _sources[source.sourceId] = source;
  }

  /// 注销渠道。
  void unregister(String sourceId) {
    _sources.remove(sourceId);
  }

  /// 按 id 解析渠道；未注册返回 null。
  MusicSource? resolve(String sourceId) => _sources[sourceId];

  /// 是否包含某渠道。
  bool contains(String sourceId) => _sources.containsKey(sourceId);

  /// 全部已注册渠道（只读视图）。
  List<MusicSource> get all => List.unmodifiable(_sources.values);

  int get length => _sources.length;
}
