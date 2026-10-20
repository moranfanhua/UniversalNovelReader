import 'package:flutter_test/flutter_test.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/comment_like_cache.dart';
import 'package:unr/sources/comment_source.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';
import 'package:unr/sources/fanqie/fanqie_api.dart';
import 'package:unr/sources/fanqie/fanqie_source.dart';
import 'package:unr/sources/ciweimao/ciweimao_api.dart';
import 'package:unr/sources/ciweimao/ciweimao_source.dart';

void main() {
  CommentLikeNotifier create() =>
      CommentLikeNotifier(const CommentLikeStatus(count: 0));

  test('上万条评论及其元数据受容量限制，保留最近访问状态', () {
    final metadata = <String, int>{};
    final cache = CommentLikeCache(capacity: 32, onEvict: metadata.remove);
    final recent = cache.putIfAbsent('recent', create);
    for (var i = 0; i < 10000; i++) {
      metadata['$i'] = i;
      cache.putIfAbsent('$i', create);
      expect(cache.putIfAbsent('recent', create), same(recent));
    }
    expect(cache.length, 32);
    expect(metadata.length, lessThanOrEqualTo(32));
    expect(cache['0'], isNull);
  });

  test('活跃监听和在途请求不淘汰，释放后恢复上限，旧引用的迟到更新仍安全', () {
    final pending = <String>{'pending'};
    final cache = CommentLikeCache(capacity: 2, isPending: pending.contains);
    final visible = cache.putIfAbsent('visible', create);
    var changes = 0;
    void listener() => changes++;
    visible.addListener(listener);
    final sending = cache.putIfAbsent('sending', create);
    sending.value = const CommentLikeStatus(count: 1, sending: true);
    final request = cache.putIfAbsent('pending', create);
    for (var i = 0; i < 1000; i++) {
      cache.putIfAbsent('$i', create);
    }
    expect(cache['visible'], same(visible));
    expect(cache['sending'], same(sending));
    expect(cache['pending'], same(request));
    expect(cache.length, 5);
    visible.value = const CommentLikeStatus(count: 2);
    expect(changes, 1);
    visible.removeListener(listener);
    sending.value = const CommentLikeStatus(count: 1, liked: true);
    pending.clear();
    cache.trim();
    expect(cache.length, 2);
    for (var i = 1000; i < 1100; i++) {
      cache.putIfAbsent('$i', create);
    }
    // Eviction removes ownership, not the caller's valid notifier reference.
    request.value = const CommentLikeStatus(count: 7);
    expect(request.value.count, 7);
  });

  test('三个书源在大量评论后保留仍在显示的共享状态，离开页面后可淘汰', () {
    final sf = SfacgApi(), fq = FanqieApi(), cw = CiweimaoApi();
    addTearDown(sf.close);
    addTearDown(fq.close);
    addTearDown(cw.close);
    final sources = <CommentSource>[
      SfacgSource(sf),
      FanqieSource(fq),
      CiweimaoSource(cw),
    ];
    ParagraphComment comment(String id) =>
        ParagraphComment(id: id, author: '', text: '', likes: 0);
    for (final source in sources) {
      final first = comment('1000001');
      final state = source.likeStatus(first);
      void listener() {}
      state.addListener(listener);
      for (var i = 0; i < 1000; i++) {
        source.likeStatus(comment('${2000000 + i}'));
      }
      expect(source.likeStatus(first), same(state), reason: source.id);
      state.removeListener(listener);
      for (var i = 0; i < 1000; i++) {
        source.likeStatus(comment('${3000000 + i}'));
      }
      expect(source.likeStatus(first), isNot(same(state)), reason: source.id);
    }
  });
}
