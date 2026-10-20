@DefaultAsset('package:unr/sources/native_chapter_crypto.dart')
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

enum ChapterCipher { aesCbc, des3Cbc, aesCtr }

class ChapterDecryptInput {
  const ChapterDecryptInput({
    required this.data,
    required this.key,
    required this.iv,
    this.cipher = ChapterCipher.aesCbc,
    this.padding = true,
  });

  final Uint8List data, key, iv;
  final ChapterCipher cipher;
  final bool padding;
}

final class _Bytes extends Struct {
  external Pointer<Uint8> data;
  @Size()
  external int length;
}

final class _Input extends Struct {
  external _Bytes data;
  external _Bytes key;
  external _Bytes iv;
  @Int32()
  external int cipher;
  @Int32()
  external int padding;
}

final class _Output extends Struct {
  external Pointer<Uint8> data;
  @Size()
  external int length;
  @Int32()
  external int status;
}

@Native<Int32 Function(Pointer<_Input>, Pointer<_Output>, Size)>(
  symbol: 'unr_chapter_decrypt_batch',
)
external int _decryptBatch(
  Pointer<_Input> input,
  Pointer<_Output> output,
  int count,
);

@Native<Void Function(Pointer<Uint8>, Size)>(symbol: 'unr_chapter_crypto_free')
external void _free(Pointer<Uint8> data, int length);

/// Shared cipher operations only. Platform keys, permissions, container parsing
/// and chapter error messages stay in the corresponding source adapters.
class NativeChapterCrypto {
  static Uint8List decrypt(ChapterDecryptInput input) {
    final result = decryptBatch([input]).single;
    if (result == null) throw const FormatException('章节解密失败');
    return result;
  }

  /// Returns null for a failed job without losing other successful results.
  static List<Uint8List?> decryptBatch(List<ChapterDecryptInput> jobs) {
    if (jobs.isEmpty) return [];
    return using((arena) {
      final inputs = arena<_Input>(jobs.length);
      final outputs = arena<_Output>(jobs.length);
      void copy(_Bytes target, Uint8List bytes) {
        target.length = bytes.length;
        target.data = bytes.isEmpty ? nullptr : arena<Uint8>(bytes.length);
        if (bytes.isNotEmpty) {
          target.data.asTypedList(bytes.length).setAll(0, bytes);
        }
      }

      try {
        for (var i = 0; i < jobs.length; i++) {
          final input = inputs[i];
          final job = jobs[i];
          copy(input.data, job.data);
          copy(input.key, job.key);
          copy(input.iv, job.iv);
          input
            ..cipher = job.cipher.index + 1
            ..padding = job.padding ? 1 : 0;
        }
        if (_decryptBatch(inputs, outputs, jobs.length) != 0) {
          throw const FormatException('章节批量解密失败');
        }
        return [
          for (var i = 0; i < jobs.length; i++)
            if (outputs[i].status == 0)
              Uint8List.fromList(outputs[i].data.asTypedList(outputs[i].length))
            else
              null,
        ];
      } finally {
        for (var i = 0; i < jobs.length; i++) {
          _free(outputs[i].data, outputs[i].length);
          final key = inputs[i].key;
          if (key.data != nullptr) {
            key.data.asTypedList(key.length).fillRange(0, key.length, 0);
          }
        }
      }
    });
  }
}
