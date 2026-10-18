import 'novel_source.dart';
import '../domain/models.dart';

/// The source, rather than a shared page, identifies an App security challenge.
class SourceVerificationRequiredException extends SourceException {
  const SourceVerificationRequiredException(
    super.message, {
    super.code,
    super.errorCode,
  });
}

/// A source owns the protocol and result parsing; the UI only hosts its document.
abstract class SourceVerificationChallenge<T> {
  const SourceVerificationChallenge();

  String get title;
  String get instruction;
  String get profileId;
  String get returnLabel => '返回';
  DateTime get expiresAt;
  SourceVerificationDocument createDocument(String nonce);
  T? parseResult(Object? value);
}

abstract interface class SourceVerificationDocument {
  String get nonce;
  Uri get uri;
  String get html;
  String get handlerName;
}

typedef SourceVerificationSolver =
    Future<T?> Function<T>(SourceVerificationChallenge<T> challenge);

enum SourceVerificationOutcome { notRequired, verified, cancelled }

abstract interface class VerifiableNovelSource implements NovelSource {
  bool get canVerifyAccess;
  Future<SourceVerificationOutcome> verifyAccess(
    SourceVerificationSolver solve,
  );
}
