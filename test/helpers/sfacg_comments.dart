import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unr/domain/models.dart';
import 'package:unr/sources/sfacg/sfacg_api.dart';
import 'package:unr/sources/sfacg/sfacg_source.dart';

http.Response response(Object? data, {int status = 200, String message = ''}) =>
    http.Response(
      jsonEncode({
        'status': {'httpCode': status, 'msg': message},
        'data': data,
      }),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

const chapter = Chapter(id: '123', title: '第一章');
const paragraph = Paragraph('原段落', remoteIndex: 6);
const text = '中文😀\n第二行[em:sfgirl:004]';
Map<String, Object> comment() => {
  'tsukkomiId': 9,
  'row': 6,
  'content': text,
  'postUser': {'nickName': '测试读者'},
};

SfacgSource source(
  Future<http.Response> Function(http.Request) handler, {
  bool loggedIn = true,
}) {
  final api = SfacgApi(client: MockClient(handler));
  if (loggedIn) {
    api.setCookie('.SFCommunity=synthetic; session_APP=synthetic-app');
  }
  return SfacgSource(api);
}
