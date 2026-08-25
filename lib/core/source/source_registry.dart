import 'music_source.dart';

/// 渠道注册与解析中心。
///
/// UI 层通过 [SourceRegistry] 获取渠道实例，
/// 永不直接 import 具体渠道实现。
class SourceRegistry {
  SourceRegistry._();

  static final SourceRegistry _instance = SourceRegistry._();

  factory SourceRegistry() => _instance;

  final Map<String, MusicSource> _sources = {};

  void register(MusicSource source) {
    _sources[source.sourceId] = source;
  }

  void registerAll(Iterable<MusicSource> sources) {
    for (final source in sources) {
      register(source);
    }
  }

  MusicSource? resolve(String sourceId) => _sources[sourceId];

  Iterable<MusicSource> get all => _sources.values;
}
