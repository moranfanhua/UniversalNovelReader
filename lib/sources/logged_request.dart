import 'package:http/http.dart' as http;

import '../data/app_log.dart';

/// Observe the existing request once, including body reads and timeouts.
/// Headers, URL, body and exception messages are deliberately never recorded.
Future<http.Response> sendLoggedRequest(
  http.Client client,
  http.BaseRequest request, {
  required String event,
  AppLog? log,
  Duration timeout = const Duration(seconds: 25),
}) async {
  final diagnostics = log ?? AppLog.instance;
  final watch = Stopwatch()..start();
  try {
    final response = await (() async => http.Response.fromStream(
      await client.send(request),
    ))().timeout(timeout);
    diagnostics.record(
      response.statusCode >= 400 ? LogLevel.warning : LogLevel.info,
      event,
      httpStatus: response.statusCode,
      elapsedMilliseconds: watch.elapsedMilliseconds,
    );
    return response;
  } catch (error, stack) {
    diagnostics.record(
      LogLevel.error,
      event,
      error: error,
      stackTrace: stack,
      elapsedMilliseconds: watch.elapsedMilliseconds,
    );
    rethrow;
  }
}
