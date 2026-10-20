import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final cppFlags = input.config.code.targetOS == OS.windows
        ? ['/EHsc', '/we4530']
        : <String>[];
    final builder = CBuilder.library(
      name: 'unr_fanqie_signature',
      assetName: 'sources/fanqie/fanqie_signature.dart',
      sources: ['lib/sources/fanqie/native/fanqie_signature.cpp'],
      language: Language.cpp,
      std: 'c++17',
      flags: cppFlags,
      // This library exposes only C buffers; no C++ objects cross its boundary.
      cppLinkStdLib: input.config.code.targetOS == OS.android
          ? 'c++_static'
          : null,
    );
    await builder.run(input: input, output: output);
    output.dependencies.add(
      input.packageRoot.resolve('lib/sources/fanqie/native/fanqie_signature.h'),
    );
    const includes = [
      'lib/sources/native',
      'third_party/mbedtls/include',
      'third_party/mbedtls/library',
    ];
    // A quoted /D value breaks cmd.exe invocation when MSVC's path has spaces.
    // Select the Mbed TLS configuration inside the force-included header.
    const forcedIncludes = ['lib/sources/native/unr_mbedtls_config.h'];
    await CBuilder.library(
      name: 'unr_mbedtls_chapter',
      sources: [
        'third_party/mbedtls/library/aes.c',
        'third_party/mbedtls/library/des.c',
        'third_party/mbedtls/library/platform_util.c',
      ],
      includes: includes,
      forcedIncludes: forcedIncludes,
      linkModePreference: LinkModePreference.static,
    ).run(input: input, output: output);
    await CBuilder.library(
      name: 'unr_chapter_crypto',
      assetName: 'sources/native_chapter_crypto.dart',
      sources: ['lib/sources/native/chapter_crypto.cpp'],
      includes: includes,
      forcedIncludes: forcedIncludes,
      libraries: ['unr_mbedtls_chapter'],
      language: Language.cpp,
      std: 'c++17',
      flags: cppFlags,
      cppLinkStdLib: input.config.code.targetOS == OS.android
          ? 'c++_static'
          : null,
    ).run(input: input, output: output);
    output.dependencies.add(
      input.packageRoot.resolve('lib/sources/native/chapter_crypto.h'),
    );
    output.dependencies.add(
      input.packageRoot.resolve('lib/sources/native/unr_mbedtls_config.h'),
    );
    for (final file in Directory.fromUri(
      input.packageRoot.resolve('third_party/mbedtls/'),
    ).listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('.h')) output.dependencies.add(file.uri);
    }
  });
}
