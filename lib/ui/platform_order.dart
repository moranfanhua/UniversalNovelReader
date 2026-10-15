import '../sources/novel_source.dart';

List<T> platformDisplayOrder<T extends NovelSource>(Iterable<T> sources) {
  final items = sources.toList();
  return [
    ...items.where((source) => source.id == 'fanqie'),
    ...items.where((source) => source.id == 'sfacg'),
    ...items.where((source) => source.id != 'fanqie' && source.id != 'sfacg'),
  ];
}
