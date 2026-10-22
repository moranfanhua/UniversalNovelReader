import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';
import '../../domain/models.dart';
import '../../domain/server_error_message.dart';
import '../../data/app_log.dart';
import '../logged_request.dart';
import '../session_validation.dart';
import 'fanqie_crypto.dart';

typedef FanqieChapterResult = ({
  String id,
  Map<String, dynamic>? data,
  Object? error,
});

class FanqieAppApi {
  FanqieAppApi({required this.client, required this.cookie, this.onChanged});
  final http.Client client;
  final String Function() cookie;
  final Future<void> Function()? onChanged;
  String deviceId = '', installId = '';
  Uint8List? _key;
  String _keyOwner = '';
  int _keyRegisterTs = 0;
  Future<void>? _initializing, _registeringKey;
  static const host = 'api5-normal-sinfonlineb.fqnovel.com';
  static const _agent =
      'com.dragon.read/65132 (Linux; U; Android 10; zh_CN; MI 12; Build/MMB29M; Cronet/TTNetVersion:9ac8d95c 2024-11-25 QuicVersion:3f326df4 2024-11-14)';
  static bool _validId(String value) =>
      RegExp(r'^[1-9]\d{5,19}$').hasMatch(value);
  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'installId': installId,
    if (_key != null) 'key': base64Encode(_key!),
    'keyOwner': _keyOwner,
    'keyRegisterTs': _keyRegisterTs,
  };
  void restore(Map<String, dynamic> data) {
    final did = '${data['deviceId'] ?? ''}', iid = '${data['installId'] ?? ''}';
    if (!_validId(did) || !_validId(iid)) {
      throw const SourceException('番茄本机设备数据无效');
    }
    final key = data['key'] == null
        ? null
        : base64Decode(data['key'] as String);
    if (key != null && key.length != 16) {
      throw const SourceException('番茄本机阅读密钥无效');
    }
    deviceId = did;
    installId = iid;
    _key = key;
    _keyOwner = '${data['keyOwner'] ?? ''}';
    _keyRegisterTs = int.tryParse('${data['keyRegisterTs']}') ?? 0;
  }

  Map<String, String> get _params => {
    'aid': '1967',
    'app_name': 'novelapp',
    'channel': 'xiaomi_1967_64',
    'device_platform': 'android',
    'device_id': deviceId,
    'iid': installId,
    'device_type': 'MI 12',
    'device_brand': 'Xiaomi',
    'os_version': '10',
    'os_api': '29',
    'version_code': '65132',
    'version_name': '6.5.1.32',
    'manifest_version_code': '65132',
    'update_version_code': '65132',
    'language': 'zh',
    'host_abi': 'arm64-v8a',
    'compliance_status': '0',
  };
  Map<String, String> get loginParameters => Map.unmodifiable(_params);

  Future<String> accountId() async => '${(await accountInfo())['user_id']}';

  Future<Map<String, dynamic>> accountInfo() async {
    await ensureDevice();
    // APK Passport SDK: AccountInfoApi -> /passport/account/info/v2/.
    final document = _document(
      await _send(
        Uri.https('security.snssdk.com', '/passport/account/info/v2/', {
          ..._params,
          'passport-sdk-version': '5051452',
        }),
      ),
    );
    final data = document['data'];
    if (document['message'] != 'success') {
      final name = data is Map ? data['name'] ?? data['error_name'] : null;
      if ('$name'.toLowerCase() == 'session_expired') {
        throw const SessionExpiredException('番茄会话已失效，请重新登录');
      }
      throw const SourceException('番茄账号检测暂未通过，请稍后重试或在官方 App 完成安全验证');
    }
    final id = data is Map ? '${data['user_id'] ?? ''}' : '';
    if (id == '0') {
      throw const SessionExpiredException('番茄会话未登录或已失效');
    }
    if (!RegExp(r'^[1-9]\d{0,19}$').hasMatch(id) ||
        BigInt.parse(id).bitLength > 64) {
      throw const SourceException('番茄账号检测返回的数据格式已变化');
    }
    return Map<String, dynamic>.from(data as Map);
  }

  Future<http.Response> _send(
    Uri uri, {
    List<int>? body,
    bool signed = true,
    bool session = true,
    String contentType = 'application/json',
  }) async {
    final request = http.Request(body == null ? 'GET' : 'POST', uri)
      ..followRedirects = false;
    request.headers.addAll({
      'User-Agent': _agent,
      if (signed) ...FanqieCrypto.sign(uri, body: body),
      if (session && cookie().isNotEmpty) 'Cookie': cookie(),
      if (body != null) 'Content-Type': contentType,
    });
    if (body != null) request.bodyBytes = body;
    final http.Response response;
    try {
      response = await sendLoggedRequest(
        client,
        request,
        event: 'http.fanqie.app',
      );
    } on TimeoutException {
      throw const SourceException('番茄 App 请求超时，请检查网络后重试');
    } on http.ClientException {
      throw const SourceException('番茄 App 网络连接失败，请稍后重试');
    }
    if (response.statusCode != 200 ||
        response.bodyBytes.isEmpty ||
        response.headers.containsKey('bdturing-verify')) {
      throw SourceException(
        '番茄 App 接口暂时无法访问，请稍后重试（HTTP ${response.statusCode}）',
        code: response.statusCode,
      );
    }
    return response;
  }

  static Map<String, dynamic> _document(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
    } catch (error, stack) {
      AppLog.instance.record(
        LogLevel.error,
        'fanqie.response_invalid',
        error: error,
        stackTrace: stack,
      );
      throw const SourceException('番茄 App 返回无法识别的数据');
    }
  }

  Future<void> ensureDevice() => _initializing ??= (() async {
    try {
      if (_validId(deviceId) && _validId(installId)) return;
      final cdid = const Uuid().v4(), clientudid = const Uuid().v4();
      final openudid = FanqieCrypto.randomBytes(
        8,
      ).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
      final now = DateTime.now().millisecondsSinceEpoch;
      final params = {..._params}
        ..remove('device_id')
        ..remove('iid');
      params.addAll({
        'tt_data': 'a',
        'cdid': cdid,
        'openudid': openudid,
        'package': 'com.dragon.read',
        'app_name': 'novel',
        'ssmix': 'a',
        'ts': '${now ~/ 1000}',
        '_rticket': '$now',
        'resolution': '1440*2392',
        'dpi': '560',
      });
      final payload = jsonEncode({
        'magic_tag': 'ss_app_log',
        '_gen_time': now,
        'header': {
          'display_name': '番茄小说',
          'aid': 1967,
          'package': 'com.dragon.read',
          'channel': 'xiaomi_1967_64',
          'app_version': '6.5.1.32',
          'version_code': 65132,
          'manifest_version_code': 65132,
          'update_version_code': 65132,
          'sdk_version': 'v04.04.05-ov-android',
          'sdk_target_version': 29,
          'os': 'Android',
          'os_version': '10',
          'os_api': 29,
          'device_model': 'MI 12',
          'device_brand': 'Xiaomi',
          'device_manufacturer': 'Google',
          'device_category': 'phone',
          'cpu_abi': 'arm64-v8a',
          'release_build': cdid,
          'density_dpi': 560,
          'display_density': 'mdpi',
          'resolution': '1440x2392',
          'language': 'zh',
          'timezone': 8,
          'access': 'wifi',
          'not_request_sender': 0,
          'openudid': openudid,
          'clientudid': clientudid,
          'sim_serial_number': [],
          'region': 'CN',
          'tz_name': 'Asia/Shanghai',
          'tz_offset': 28800,
          'sim_region': 'cn',
        },
      });
      final response = await _send(
        Uri.https('log.snssdk.com', '/service/2/device_register/', params),
        body: FanqieCrypto.ttEncrypt(gzip.encode(utf8.encode(payload))),
        signed: false,
        session: false,
        contentType: 'application/octet-stream;tt-data=a',
      );
      final data = _document(response);
      final did = '${data['device_id_str'] ?? data['device_id'] ?? ''}',
          iid = '${data['install_id_str'] ?? data['install_id'] ?? ''}';
      if (!_validId(did) || !_validId(iid)) {
        throw const SourceException('番茄未返回有效本机设备标识');
      }
      deviceId = did;
      installId = iid;
      await onChanged?.call();
    } finally {
      _initializing = null;
    }
  })();
  Future<Map<String, dynamic>> request(
    String path, {
    Map<String, String> query = const {},
    Map<String, dynamic>? body,
    String hostname = host,
    bool useSession = true,
  }) async {
    final data = await _requestData(
      path,
      query: query,
      body: body,
      hostname: hostname,
      useSession: useSession,
    );
    if (data is! Map) throw const SourceException('番茄 App 返回无效数据');
    return Map<String, dynamic>.from(data);
  }

  Future<Map<String, int>> bookFavoriteCounts(Iterable<String> bookIds) async {
    final ids = bookIds.toSet();
    if (ids.isEmpty) return {};
    if (ids.length > 20 ||
        ids.any((id) => !RegExp(r'^[1-9]\d{14,19}$').hasMatch(id))) {
      throw const SourceException('番茄收藏数查询作品 ID 无效');
    }
    final data = await bookDetails(ids);
    final counts = <String, int>{};
    for (final info in data.whereType<Map>()) {
      final id = '${info['book_id']}';
      // all_bookshelf_count is the recent count; use cumulative shelf history.
      final count = Book.parseFavoriteCount(info['shelf_cnt_history']);
      if (ids.contains(id) && count != null) counts[id] = count;
    }
    return counts;
  }

  Future<List<dynamic>> bookDetails(Iterable<String> bookIds) async {
    final ids = bookIds.toSet();
    if (ids.isEmpty) return [];
    // Official BookshelfSyncSystem batches at most 100 IDs (MBookDetailRequest).
    if (ids.length > 100 ||
        ids.any((id) => !RegExp(r'^[1-9]\d{14,19}$').hasMatch(id))) {
      throw const SourceException('番茄作品详情查询 ID 无效');
    }
    final data = await _requestData(
      '/reading/bookapi/multi-detail/v/',
      query: {'book_id': ids.join(',')},
      useSession: false,
    );
    if (data is! List) throw const SourceException('番茄作品详情数据格式已变化');
    return data;
  }

  Future<dynamic> _requestData(
    String path, {
    Map<String, String> query = const {},
    Map<String, dynamic>? body,
    String hostname = host,
    bool useSession = true,
  }) async {
    if (!{host, 'reading.snssdk.com', 'novel.snssdk.com'}.contains(hostname) ||
        !path.startsWith('/') ||
        path.contains('?')) {
      throw const SourceException('番茄 App 请求地址无效');
    }
    await ensureDevice();
    final response = await _send(
      Uri.https(hostname, path, {..._params, ...query}),
      body: body == null ? null : utf8.encode(jsonEncode(body)),
      session: useSession,
    );
    final doc = _document(response);
    final code = int.tryParse('${doc['code']}') ?? -1;
    if (code != 0) {
      final serverMessage = ServerErrorMessage.parse(
        doc['message'] ?? doc['msg'],
        responseData: doc,
        secrets: [
          cookie().split(RegExp(r'[=;]')),
          deviceId,
          installId,
          query,
          body,
        ],
      );
      AppLog.instance.record(
        LogLevel.warning,
        'fanqie.request_rejected',
        error: SourceException('', code: code),
        httpStatus: response.statusCode,
        serverMessage: serverMessage,
      );
      final message = '番茄 App 请求失败（状态 $code），请检查会话或阅读权限';
      throw SourceException(
        serverMessage?.appendTo(message) ?? message,
        code: code,
      );
    }
    return doc['data'];
  }

  Future<void> _ensureKey() {
    final owner = sha256.convert(utf8.encode(cookie())).toString();
    if (_key != null && _keyOwner == owner) return Future<void>.value();
    return _registeringKey ??= _registerKey(owner);
  }

  Future<void> _registerKey(String owner) async {
    try {
      var userId = '0';
      if (cookie().isNotEmpty) {
        userId = await accountId();
      }
      final data = await request(
        '/reading/crypt/registerkey',
        hostname: 'reading.snssdk.com',
        body: {
          'content': FanqieCrypto.registerRequest(deviceId, userId: userId),
          'keyver': 1,
        },
      );
      final key = FanqieCrypto.decryptBlob(
        '${data['key'] ?? ''}',
        FanqieCrypto.hex('ac25c67ddd8f38c1b37a2348828e222e'),
      );
      if (key.length != 16) throw const SourceException('番茄返回的阅读密钥无效');
      if (owner != sha256.convert(utf8.encode(cookie())).toString()) {
        throw const SourceException('番茄账号已切换，请重新下载章节');
      }
      _key = key;
      _keyOwner = owner;
      _keyRegisterTs = int.tryParse('${data['key_register_ts']}') ?? 0;
      await onChanged?.call();
    } finally {
      _registeringKey = null;
    }
  }

  Future<Map<String, dynamic>> chapter(String bookId, String chapterId) async {
    await ensureDevice();
    await _ensureKey();
    var data = await request(
      '/reading/reader/full/v/',
      hostname: 'reading.snssdk.com',
      query: {
        'book_id': bookId,
        'item_id': chapterId,
        'req_type': '0',
        'novel_text_type': '1',
      },
    );
    if ('${data['crypt_status']}' == '2') {
      _key = null;
      _registeringKey = null;
      await _ensureKey();
      data = await request(
        '/reading/reader/full/v/',
        hostname: 'reading.snssdk.com',
        query: {
          'book_id': bookId,
          'item_id': chapterId,
          'req_type': '0',
          'novel_text_type': '1',
        },
      );
    }
    return _decodeChapter(bookId, chapterId, data, _key!);
  }

  /// APK ReaderDownload divides chapters into groups of 30, req_type=Download.
  Future<List<FanqieChapterResult>> chapters(
    String bookId,
    List<String> chapterIds,
  ) async {
    if (chapterIds.isEmpty) return [];
    final validId = RegExp(r'^[1-9]\d{14,19}$');
    if (!validId.hasMatch(bookId) ||
        chapterIds.length > 30 ||
        chapterIds.toSet().length != chapterIds.length ||
        chapterIds.any((id) => !validId.hasMatch(id))) {
      throw const SourceException('番茄批量下载作品或章节 ID 无效');
    }
    final session = cookie();
    void checkSession() {
      if (cookie() != session) {
        throw const SourceException('番茄账号已切换，请重新下载章节');
      }
    }

    await ensureDevice();
    await _ensureKey();
    checkSession();
    Future<Map<String, dynamic>> fetch(List<String> ids) => request(
      '/reading/reader/batch_full/v/',
      hostname: 'reading.snssdk.com',
      query: {
        'book_id': bookId,
        'item_ids': ids.join(','),
        'req_type': '0',
        'novel_text_type': '1',
        'key_register_ts': '$_keyRegisterTs',
      },
    );
    final key = _key!;
    final data = await fetch(chapterIds);
    checkSession();
    final results = <String, FanqieChapterResult>{};
    final expired = <String>[];
    void decodeGroup(
      List<String> ids,
      Map<String, dynamic> response,
      Uint8List key,
    ) {
      final encryptedIds = <String>[];
      final values = <String, Map<String, dynamic>>{};
      for (final id in ids) {
        try {
          final raw = response[id];
          if (raw is! Map) throw const SourceException('番茄未返回该章节正文');
          final value = Map<String, dynamic>.from(raw);
          final crypt = _chapterCrypt(bookId, id, value);
          if (crypt == 0) {
            values[id] = value;
            encryptedIds.add(id);
          } else {
            results[id] = (
              id: id,
              data: _decodeChapter(bookId, id, value, key),
              error: null,
            );
          }
        } catch (error) {
          results[id] = (id: id, data: null, error: error);
        }
      }
      final decrypted = FanqieCrypto.decryptBlobs([
        for (final id in encryptedIds) '${values[id]!['content'] ?? ''}',
      ], key);
      for (var i = 0; i < encryptedIds.length; i++) {
        final id = encryptedIds[i];
        try {
          final blob = decrypted[i];
          if (blob.error != null) throw blob.error!;
          results[id] = (
            id: id,
            data: _decodeChapter(
              bookId,
              id,
              values[id]!,
              key,
              plaintext: blob.bytes,
            ),
            error: null,
          );
        } catch (error) {
          results[id] = (id: id, data: null, error: error);
        }
      }
    }

    final current = <String>[];
    for (final id in chapterIds) {
      final raw = data[id];
      if (raw is Map && '${raw['crypt_status']}' == '2') {
        expired.add(id);
      } else {
        current.add(id);
      }
    }
    decodeGroup(current, data, key);
    if (expired.isNotEmpty) {
      try {
        if (identical(_key, key)) _key = null;
        await _ensureKey();
        checkSession();
        final refreshedKey = _key!;
        final retry = await fetch(expired);
        checkSession();
        decodeGroup(expired, retry, refreshedKey);
      } catch (error) {
        for (final id in expired) {
          results[id] = (id: id, data: null, error: error);
        }
      }
    }
    checkSession();
    return chapterIds.map((id) => results[id]!).toList();
  }

  int _chapterCrypt(
    String bookId,
    String chapterId,
    Map<String, dynamic> data,
  ) {
    final metadata = data['novel_data'];
    if (metadata is! Map ||
        '${metadata['book_id']}' != bookId ||
        '${metadata['item_id']}' != chapterId) {
      throw const SourceException('番茄 App 未返回对应章节');
    }
    if ((int.tryParse('${data['code'] ?? 0}') ?? -1) != 0 ||
        (int.tryParse('${data['code_i32'] ?? 0}') ?? -1) != 0 ||
        data['is_preview'] == true ||
        data['is_content_incomplete'] == true ||
        data['block_data'] != null) {
      throw const SourceException('番茄章节不可读取或仅返回试读，请确认官方阅读权限');
    }
    final crypt = int.tryParse('${data['crypt_status']}');
    if (crypt == 2) throw const SourceException('番茄阅读密钥已过期，请重试');
    if (crypt != 0 && crypt != 1) throw const SourceException('番茄正文加密格式已变化');
    return crypt!;
  }

  Map<String, dynamic> _decodeChapter(
    String bookId,
    String chapterId,
    Map<String, dynamic> data,
    Uint8List key, {
    Uint8List? plaintext,
  }) {
    final crypt = _chapterCrypt(bookId, chapterId, data);
    final encrypted = '${data['content'] ?? ''}';
    List<int> bytes = crypt == 1
        ? utf8.encode(encrypted)
        : plaintext ?? FanqieCrypto.decryptBlob(encrypted, key);
    if (bytes.length >= 2 && bytes[0] == 31 && bytes[1] == 139) {
      try {
        bytes = gzip.decode(bytes);
      } catch (_) {
        throw const SourceException('番茄正文解压失败');
      }
    } else if (data['compress_status'] != null &&
        '${data['compress_status']}' != '0') {
      try {
        bytes = ZLibDecoder().convert(bytes);
      } catch (_) {
        throw const SourceException('番茄正文压缩格式已变化');
      }
    }
    try {
      return {...data, 'content': utf8.decode(bytes)};
    } catch (_) {
      throw const SourceException('番茄正文字符编码无效');
    }
  }
}
