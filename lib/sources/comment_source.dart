import 'package:flutter/foundation.dart';
import '../domain/models.dart';

enum CommentSort { hot, latest }

class CommentCapabilities {
  const CommentCapabilities({
    this.counts = false,
    this.post = false,
    this.replies = false,
    this.reply = false,
    this.replyToReply = false,
    this.likes = false,
    this.replyLikes = false,
    this.sorts = const {CommentSort.latest},
  }) : assert(!reply || replies),
       assert(!replyToReply || reply);
  final bool counts, post, replies, reply, replyToReply, likes, replyLikes;
  final Set<CommentSort> sorts;
  bool canLike(ParagraphComment comment) =>
      comment.isReply ? replyLikes : likes;
  bool canReply(ParagraphComment comment) =>
      comment.isReply ? replyToReply : reply;
}

class CommentPage {
  const CommentPage(this.items, {this.nextCursor});
  final List<ParagraphComment> items;
  // Opaque to the UI: a provider can use page numbers, offsets or server tokens.
  final String? nextCursor;
}

class CommentLocation {
  const CommentLocation({
    this.book,
    required this.chapter,
    required this.paragraph,
  });
  final Book? book;
  final Chapter chapter;
  final Paragraph paragraph;
}

class CommentPart {
  const CommentPart.text(this.text) : image = null, inline = false;
  const CommentPart.image(this.image, {this.text = '', this.inline = false});
  final String text;
  final String? image;
  final bool inline;
}

/// Optional comment service for a book source. Providers own authentication,
/// protocol IDs, pagination, write semantics and normalized reply ordering.
abstract class CommentSource {
  String get id;
  String get name;
  bool get hasSession;
  CommentCapabilities get commentCapabilities;
  Future<CommentPage> commentPage(
    CommentLocation location, {
    String? cursor,
    CommentSort sort = CommentSort.latest,
  });

  Future<int> paragraphCommentCount(
    CommentLocation location, {
    bool refresh = false,
  }) => Future.error(const SourceException('当前书源不支持段评计数'));
  Future<List<ParagraphComment>> repliesFor(
    CommentLocation location,
    ParagraphComment root, {
    bool Function()? cancelled,
  }) => Future.error(const SourceException('当前书源不支持读取回复'));
  Future<void> publishComment(CommentLocation location, String text) =>
      Future.error(const SourceException('当前书源不支持发送段评'));
  Future<void> postReply(
    ParagraphComment root,
    String text, {
    ParagraphComment? target,
    CommentLocation? location,
  }) => Future.error(const SourceException('当前书源不支持发送回复'));
  ValueListenable<CommentLikeStatus> likeStatus(
    ParagraphComment comment, {
    CommentLocation? location,
    ParagraphComment? root,
  }) => _StaticLikeStatus(CommentLikeStatus(count: comment.likes));
  Future<void> likeComment(
    ParagraphComment comment, {
    CommentLocation? location,
    ParagraphComment? root,
  }) => Future.error(const SourceException('当前书源不支持点赞'));

  List<CommentPart> commentContent(String text) => [CommentPart.text(text)];
  String? avatarAddress(String address) => commentImageAddress(address);
  List<ParagraphComment> orderedReplies(Iterable<ParagraphComment> comments) {
    final indexed = comments.toList().asMap().entries.toList();
    if (indexed.any((entry) => DateTime.tryParse(entry.value.date) == null)) {
      return indexed.map((entry) => entry.value).toList();
    }
    indexed.sort((a, b) {
      final first = DateTime.tryParse(a.value.date),
          second = DateTime.tryParse(b.value.date);
      final byDate = first!.compareTo(second!);
      return byDate == 0 ? a.key.compareTo(b.key) : byDate;
    });
    return indexed.map((entry) => entry.value).toList();
  }
}

class _StaticLikeStatus implements ValueListenable<CommentLikeStatus> {
  const _StaticLikeStatus(this.value);
  @override
  final CommentLikeStatus value;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

String? commentImageAddress(String address) {
  final uri = Uri.tryParse(
    address.startsWith('//') ? 'https:$address' : address,
  );
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}
