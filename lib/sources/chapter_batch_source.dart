import '../domain/models.dart';
import 'novel_source.dart';

/// Offline downloads use the platform's App protocol and bounded batch size.
abstract interface class ChapterBatchSource implements NovelSource {
  /// Positive limits derived from this platform's App download queue.
  int get chapterBatchSize;
  int get chapterBatchConcurrency;
  Future<List<ChapterBatchResult>> readChapterBatch(
    Book book,
    List<Chapter> chapters,
  );
}

class ChapterBatchResult {
  const ChapterBatchResult.success(this.id, ChapterContent value)
    : content = value,
      error = null;
  const ChapterBatchResult.failure(this.id, Object reason)
    : content = null,
      error = reason;

  final String id;
  final ChapterContent? content;
  final Object? error;
}
