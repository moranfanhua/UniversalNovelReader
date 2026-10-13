import 'dart:typed_data';

class Chapter {
  const Chapter({
    required this.id,
    required this.title,
    this.volume = '',
    this.vip = false,
    this.url = '',
  });
  final String id, title, volume, url;
  final bool vip;
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'volume': volume,
    'vip': vip,
    'url': url,
  };
  factory Chapter.fromJson(Map<String, dynamic> j) => Chapter(
    id: j['id'],
    title: j['title'],
    volume: j['volume'] ?? '',
    vip: j['vip'] ?? false,
    url: j['url'] ?? '',
  );
}

class Book {
  const Book({
    required this.id,
    required this.title,
    required this.author,
    required this.chapters,
    this.source = 'sfacg',
    this.cover = '',
    this.description = '',
    this.updatedAt,
  });
  final String id, title, author, source, cover, description;
  final List<Chapter> chapters;
  final DateTime? updatedAt;
  String get key => '$source:$id';
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'source': source,
    'cover': cover,
    'description': description,
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
    'chapters': chapters.map((c) => c.toJson()).toList(),
  };
  factory Book.fromJson(Map<String, dynamic> j) => Book(
    id: j['id'],
    title: j['title'],
    author: j['author'],
    source: j['source'],
    cover: j['cover'] ?? '',
    description: j['description'] ?? '',
    updatedAt: DateTime.tryParse('${j['updatedAt'] ?? ''}')?.toUtc(),
    chapters: (j['chapters'] as List)
        .map((c) => Chapter.fromJson(Map<String, dynamic>.from(c)))
        .toList(),
  );
}

class Paragraph {
  const Paragraph(this.text, {this.image, this.remoteIndex});
  final String text;
  final String? image;
  final int? remoteIndex;
  Map<String, dynamic> toJson() => {
    'text': text,
    'image': image,
    'remoteIndex': remoteIndex,
  };
  factory Paragraph.fromJson(Map<String, dynamic> j) =>
      Paragraph(j['text'], image: j['image'], remoteIndex: j['remoteIndex']);
}

class ChapterContent {
  const ChapterContent(this.paragraphs);
  final List<Paragraph> paragraphs;
  Map<String, dynamic> toJson() => {
    'paragraphs': paragraphs.map((p) => p.toJson()).toList(),
  };
  factory ChapterContent.fromJson(Map<String, dynamic> j) => ChapterContent(
    (j['paragraphs'] as List)
        .map((p) => Paragraph.fromJson(Map<String, dynamic>.from(p)))
        .toList(),
  );
}

class ParagraphComment {
  const ParagraphComment({
    required this.id,
    required this.author,
    required this.text,
    this.likes = 0,
    this.replyCount = 0,
    this.date = '',
    this.paragraphText = '',
    this.avatar = '',
    this.replies = const [],
    this.isReply = false,
  });
  final String id, author, text, date, paragraphText, avatar;
  final int likes, replyCount;
  final List<ParagraphComment> replies;
  final bool isReply;
}

class CommentLikeStatus {
  const CommentLikeStatus({
    required this.count,
    this.liked = false,
    this.sending = false,
    this.message,
  });
  final int count;
  final bool liked, sending;
  final String? message;
}

class ImportedBook {
  const ImportedBook(this.book, this.contents, this.images);
  final Book book;
  final Map<String, ChapterContent> contents;
  final Map<String, Uint8List> images;
}

class SourceException implements Exception {
  const SourceException(this.message, {this.code = 0});
  final String message;
  final int code;
  @override
  String toString() => message;
}
