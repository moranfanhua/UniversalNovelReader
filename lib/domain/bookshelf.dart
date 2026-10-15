class Bookshelf {
  const Bookshelf({
    required this.id,
    required this.name,
    required this.source,
    required this.remoteId,
    required this.bookKeys,
  });
  final String id, name, source, remoteId;
  final List<String> bookKeys;

  Bookshelf copyWith({List<String>? bookKeys}) => Bookshelf(
    id: id,
    name: name,
    source: source,
    remoteId: remoteId,
    bookKeys: bookKeys ?? this.bookKeys,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'source': source,
    'remoteId': remoteId,
    'bookKeys': bookKeys,
  };

  factory Bookshelf.fromJson(Map<String, dynamic> json) => Bookshelf(
    id: json['id'],
    name: json['name'],
    source: json['source'],
    remoteId: json['remoteId'],
    bookKeys: (json['bookKeys'] as List).cast<String>(),
  );
}
