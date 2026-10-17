import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import '../../domain/models.dart';

class CiweimaoParser {
  static final _id = RegExp(r'^[1-9]\d{0,11}$');
  static const linkHosts = {
    'ciweimao.com',
    'www.ciweimao.com',
    'wap.ciweimao.com',
    'mip.ciweimao.com',
    'hbooker.com',
    'www.hbooker.com',
    'wap.hbooker.com',
  };
  static String numericId(Object? value) {
    final id = '$value';
    if (!_id.hasMatch(id)) throw const SourceException('刺猬猫作品或章节编号无效');
    return id;
  }

  static String bookId(String input) {
    final value = input.trim().replaceFirst(RegExp(r'^ciweimao:'), '');
    if (_id.hasMatch(value)) return value;
    final match = RegExp(r'https?://[^\s<>「」“”]+').firstMatch(value);
    final uri = match == null
        ? null
        : Uri.tryParse(match[0]!.replaceAll(RegExp(r'[，。；）)]+$'), ''));
    if (uri != null &&
        linkHosts.contains(uri.host.toLowerCase()) &&
        uri.userInfo.isEmpty &&
        (!uri.hasPort || uri.port == 443 || uri.port == 80)) {
      final path = RegExp(r'^/book/([1-9]\d{0,11})/?$').firstMatch(uri.path);
      if (path != null) return path[1]!;
    }
    throw const SourceException('请输入刺猬猫作品链接或 ciweimao:作品ID');
  }

  static Map<String, dynamic> object(Object? value, String what) {
    if (value is! Map) throw SourceException('刺猬猫$what格式已变化');
    return Map<String, dynamic>.from(value);
  }

  static List<dynamic> list(Object? value, String what) {
    if (value is! List) throw SourceException('刺猬猫$what格式已变化');
    return value;
  }

  static DateTime? time(Object? value) {
    final raw = '$value';
    final local = RegExp(
      r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$',
    ).hasMatch(raw);
    return DateTime.tryParse(
      local ? '${raw.replaceFirst(' ', 'T')}+08:00' : raw,
    )?.toUtc();
  }

  static String? imageAddress(String address) {
    final uri = Uri.tryParse(
      address.startsWith('//') ? 'https:$address' : address,
    );
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort && uri.port != 443 && uri.port != 80) {
      return null;
    }
    return uri
        .replace(scheme: 'https', port: uri.hasPort ? 443 : null)
        .toString();
  }

  static Book book(
    Map<String, dynamic> info, {
    List<Chapter> chapters = const [],
  }) {
    final id = numericId(info['book_id']);
    final title = '${info['book_name'] ?? ''}'.trim();
    if (title.isEmpty || '${info['book_type'] ?? 1}' != '1') {
      throw const SourceException('刺猬猫未返回有效的小说作品详情');
    }
    final last = info['last_chapter_info'];
    return Book(
      id: id,
      source: 'ciweimao',
      title: title,
      author: '${info['author_name'] ?? ''}',
      description: '${info['description'] ?? ''}',
      cover: imageAddress('${info['cover'] ?? ''}') ?? '',
      favoriteCount: Book.parseFavoriteCount(info['total_favor']),
      wordCount: Book.parseWordCount(info['total_word_count']),
      updatedAt: time(last is Map ? last['uptime'] : info['uptime']),
      chapters: chapters,
    );
  }

  static List<Chapter> directory(Map<String, dynamic> data) {
    final divisions = list(
      data['chapter_list'],
      '分卷目录',
    ).map((v) => object(v, '分卷')).toList();
    final divisionIds = <String>{}, indices = <int>{};
    for (final division in divisions) {
      final id = numericId(division['division_id']);
      final index = int.tryParse('${division['division_index']}');
      if (!divisionIds.add(id) ||
          index == null ||
          index < 0 ||
          !indices.add(index) ||
          '${division['division_name'] ?? ''}'.trim().isEmpty) {
        throw const SourceException('刺猬猫分卷编号、名称或顺序无效');
      }
    }
    divisions.sort(
      (a, b) => int.parse(
        '${a['division_index']}',
      ).compareTo(int.parse('${b['division_index']}')),
    );
    final result = <Chapter>[], seen = <String>{};
    for (final division in divisions) {
      final rows = list(
        division['chapter_list'],
        '章节目录',
      ).map((v) => object(v, '章节')).toList();
      final orders = <int>{};
      for (final row in rows) {
        final id = numericId(row['chapter_id']);
        final order = int.tryParse('${row['chapter_index']}');
        if (!seen.add(id) ||
            order == null ||
            order < 0 ||
            !orders.add(order) ||
            '${row['chapter_title'] ?? ''}'.trim().isEmpty) {
          throw const SourceException('刺猬猫章节编号、名称或顺序无效');
        }
      }
      rows.sort(
        (a, b) => int.parse(
          '${a['chapter_index']}',
        ).compareTo(int.parse('${b['chapter_index']}')),
      );
      for (final row in rows) {
        if ('${row['is_valid'] ?? 1}' == '0') continue;
        result.add(
          Chapter(
            id: '${row['chapter_id']}',
            title: '${row['chapter_title']}',
            volume: '${division['division_name']}',
            vip: '${row['is_paid']}' == '1',
            wordCount: Book.parseWordCount(row['word_count']),
          ),
        );
      }
    }
    return result;
  }

  static ChapterContent content(
    String text, {
    String authorSay = '',
    String? cdnHost,
    List<String> oldHosts = const [],
  }) {
    final paragraphs = _paragraphs(
      text,
      remote: true,
      cdnHost: cdnHost,
      oldHosts: oldHosts,
    );
    if (paragraphs.isEmpty) throw const SourceException('刺猬猫未返回完整正文，请重试');
    if (authorSay.trim().isNotEmpty) {
      paragraphs.add(const Paragraph('作者的话'));
      paragraphs.addAll(
        _paragraphs(
          authorSay,
          remote: false,
          cdnHost: cdnHost,
          oldHosts: oldHosts,
        ),
      );
    }
    return ChapterContent(paragraphs);
  }

  static List<Paragraph> _paragraphs(
    String value, {
    required bool remote,
    String? cdnHost,
    required List<String> oldHosts,
  }) {
    final text = value
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(RegExp(r'<p(?:\s[^>]*)?>', caseSensitive: false), '')
        .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n');
    // PageUtil.getPages splits on \n+ and uses the unfiltered row index + 1.
    final rows = text.split(RegExp(r'\n+'));
    final result = <Paragraph>[];
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final fragment = html.parseFragment(row);
      if (fragment.querySelector('audio,video,iframe,object,embed') != null) {
        throw const SourceException('本章包含暂不支持的媒体，请在刺猬猫官方 App 阅读');
      }
      var pending = '';
      final remoteIndex = remote ? index + 1 : null;
      void flush() {
        if (pending.trim().isNotEmpty) {
          result.add(Paragraph(pending.trim(), remoteIndex: remoteIndex));
        }
        pending = '';
      }

      void visit(Node node) {
        if (node is Text) {
          pending += node.text;
          return;
        }
        if (node is Element) {
          if (node.localName == 'img') {
            flush();
            var address = imageAddress(node.attributes['src'] ?? '');
            if (address == null) throw const SourceException('刺猬猫章节插图地址无效');
            final uri = Uri.parse(address);
            if (cdnHost != null && oldHosts.contains(uri.host)) {
              address = uri.replace(host: cdnHost).toString();
            }
            result.add(Paragraph('', image: address, remoteIndex: remoteIndex));
            return;
          }
          if (node.localName == 'br') {
            pending += '\n';
            return;
          }
          if (['script', 'style'].contains(node.localName)) return;
        }
        for (final child in node.nodes) {
          visit(child);
        }
      }

      visit(fragment);
      flush();
    }
    return result;
  }
}
