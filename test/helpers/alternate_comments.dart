import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/comment_source.dart';

const root = ParagraphComment(
  id: 'thread-uuid',
  author: '楼主',
  authorId: 'user-root',
  text: '主评论',
  replyCount: 2,
);
const oldReply = ParagraphComment(
  id: 'reply-old',
  author: '老读者',
  authorId: 'user-old',
  text: '旧回复',
  date: '2026-10-12T12:00:00',
  isReply: true,
);
const newReply = ParagraphComment(
  id: 'reply-new',
  author: '新读者',
  text: '新回复',
  date: '2026-10-13T12:00:00',
  isReply: true,
);

// Deliberately different from SFACG: UUID IDs, opaque cursor and independent
// reply target fields. This is a test provider, not another website adapter.
class AlternateComments extends CommentSource {
  AlternateComments({this.readOnly = false, this.replyToReply = true});
  final bool readOnly, replyToReply;
  final cursors = <String?>[];
  final locations = <CommentLocation>[];
  final writes = <Map<String, String>>[];
  final likes = <String, ValueNotifier<CommentLikeStatus>>{};
  int counts = 0;
  @override
  String get id => 'alternate';
  @override
  String get name => '另一个平台';
  @override
  bool get hasSession => true;
  @override
  CommentCapabilities get commentCapabilities => readOnly
      ? const CommentCapabilities()
      : CommentCapabilities(
          counts: true,
          post: true,
          replies: true,
          reply: true,
          replyToReply: replyToReply,
          replyLikes: true,
        );
  @override
  Future<CommentPage> commentPage(
    CommentLocation location, {
    String? cursor,
    CommentSort sort = CommentSort.latest,
  }) async {
    expect(sort, CommentSort.latest);
    locations.add(location);
    cursors.add(cursor);
    return cursor == null
        ? const CommentPage([root], nextCursor: 'next/token:opaque')
        : const CommentPage([
            ParagraphComment(
              id: 'thread-two',
              author: '其他人',
              text: '[em:sfgirl:004]原始文本',
            ),
          ]);
  }

  @override
  Future<int> paragraphCommentCount(
    CommentLocation location, {
    bool refresh = false,
  }) async {
    locations.add(location);
    counts++;
    return 7;
  }

  @override
  Future<List<ParagraphComment>> repliesFor(
    CommentLocation location,
    ParagraphComment root, {
    bool Function()? cancelled,
  }) async {
    expect(root.id, 'thread-uuid');
    locations.add(location);
    return [newReply, oldReply];
  }

  @override
  Future<void> publishComment(CommentLocation location, String text) async {
    writes.add({'paragraphId': location.paragraph.remoteId!, 'body': text});
  }

  @override
  Future<void> postReply(
    ParagraphComment root,
    String text, {
    ParagraphComment? target,
    CommentLocation? location,
  }) async {
    writes.add({
      'threadId': root.id,
      'replyToId': target!.id,
      'replyToUser': target.authorId,
      'body': text,
    });
    locations.add(location!);
  }

  @override
  ValueNotifier<CommentLikeStatus> likeStatus(
    ParagraphComment comment, {
    CommentLocation? location,
    ParagraphComment? root,
  }) => likes.putIfAbsent(
    comment.id,
    () => ValueNotifier(CommentLikeStatus(count: comment.likes)),
  );
  @override
  Future<void> likeComment(
    ParagraphComment comment, {
    CommentLocation? location,
    ParagraphComment? root,
  }) async {
    expect(root!.id, 'thread-uuid');
    locations.add(location!);
    final state = likeStatus(comment);
    state.value = CommentLikeStatus(count: state.value.count + 1, liked: true);
  }

  void dispose() {
    for (final state in likes.values) {
      state.dispose();
    }
  }
}

class PreviewComments extends AlternateComments {
  @override
  Future<int> paragraphCommentCount(
    CommentLocation location, {
    bool refresh = false,
  }) async {
    locations.add(location);
    return int.parse(location.chapter.id) * 11;
  }
}
