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
  DateTime get expiresAt;
  T? parseResult(Object? value);
}

abstract class SourceWebVerificationChallenge<T>
    extends SourceVerificationChallenge<T> {
  const SourceWebVerificationChallenge();

  String get profileId;
  String get returnLabel => '返回';
  SourceVerificationDocument createDocument(String nonce);
}

/// The source owns sending, cooldowns and server confirmation. The form only
/// collects the code and hosts any preceding human verification.
abstract class SourceSmsVerificationChallenge
    extends SourceVerificationChallenge<bool> {
  const SourceSmsVerificationChallenge();

  String get maskedDestination;
  DateTime? get resendAt;
  bool get canSubmit;
  Future<bool> sendCode(SourceVerificationSolver solve);
  Future<void> submitCode(String code);
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
