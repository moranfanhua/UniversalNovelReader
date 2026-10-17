import 'novel_source.dart';

const sourceDisplayOrder = ['qidian', 'fanqie', 'ciweimao', 'sfacg'];

List<T> platformDisplayOrder<T extends NovelSource>(Iterable<T> sources) {
  final items = sources.toList();
  return [
    for (final id in sourceDisplayOrder)
      ...items.where((source) => source.id == id),
    ...items.where((source) => !sourceDisplayOrder.contains(source.id)),
  ];
}
