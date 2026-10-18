import '../domain/models.dart';

/// Only explicit authentication rejection or an anonymous account response
/// establishes expiry. Transport, security challenges and schema errors do not.
class SessionExpiredException extends SourceException {
  const SessionExpiredException(super.message, {super.code, super.errorCode});
}
