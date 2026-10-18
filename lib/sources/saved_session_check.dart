import '../data/app_log.dart';
import 'ciweimao/ciweimao_auth.dart';
import 'ciweimao/ciweimao_source.dart';
import 'fanqie/fanqie_source.dart';
import 'novel_source.dart';
import 'qidian/qidian_source.dart';
import 'session_validation.dart';
import 'sfacg/sfacg_source.dart';

class ExpiredSourceSession {
  ExpiredSourceSession._(this.sourceName, this._isCurrent);

  final String sourceName;
  final bool Function() _isCurrent;

  // A login or logout while another platform is still responding makes the
  // earlier result obsolete. Check again immediately before displaying it.
  bool get isCurrent => _isCurrent();
}

/// Check saved App sessions independently. Never log credentials, remove saved
/// sessions, or let one platform's connectivity prevent another's check.
Future<List<ExpiredSourceSession>> checkSavedSessions(
  Iterable<NovelSource> sources,
) async {
  final probes = sources.map(_probeFor).whereType<_SessionProbe>().toList();
  final results = await Future.wait(
    probes.map((probe) async {
      try {
        await probe.validate();
      } on SessionExpiredException {
        return ExpiredSourceSession._(probe.name, probe.isCurrent);
      } catch (error, stack) {
        AppLog.instance.record(
          LogLevel.warning,
          'session.${probe.id}.startup_check_failed',
          error: error,
          stackTrace: stack,
        );
      }
      return null;
    }),
  );
  return results.whereType<ExpiredSourceSession>().toList();
}

_SessionProbe? _probeFor(NovelSource source) {
  if (source is SfacgSource && source.api.hasSession) {
    final api = source.api;
    final community = api.cookies['.SFCommunity'];
    final app = api.cookies['session_APP'];
    return _SessionProbe(
      source,
      api.checkSession,
      () =>
          api.hasSession &&
          api.cookies['.SFCommunity'] == community &&
          api.cookies['session_APP'] == app,
    );
  }
  if (source is FanqieSource && source.api.hasSession) {
    final api = source.api, cookie = api.cookie;
    return _SessionProbe(
      source,
      api.checkSession,
      () => api.hasSession && api.cookie == cookie,
    );
  }
  if (source is QidianSource && source.api.hasSession) {
    final api = source.api, session = api.credentials;
    return _SessionProbe(
      source,
      api.checkSession,
      () => identical(api.credentials, session),
    );
  }
  if (source is CiweimaoSource && source.api.hasSession) {
    final api = source.api, generation = api.sessionGeneration;
    return _SessionProbe(
      source,
      CiweimaoAuth(api).checkSession,
      () => api.hasSession && api.sessionGeneration == generation,
    );
  }
  return null;
}

class _SessionProbe {
  _SessionProbe(NovelSource source, this.validate, this.isCurrent)
    : id = source.id,
      name = source.name;

  final String id, name;
  final Future<void> Function() validate;
  final bool Function() isCurrent;
}
