import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final builder = CBuilder.library(
      name: 'unr_fanqie_signature',
      assetName: 'sources/fanqie/fanqie_signature.dart',
      sources: ['lib/sources/fanqie/native/fanqie_signature.cpp'],
      language: Language.cpp,
      std: 'c++17',
      // This library exposes only C buffers; no C++ objects cross its boundary.
      cppLinkStdLib: input.config.code.targetOS == OS.android
          ? 'c++_static'
          : null,
    );
    await builder.run(input: input, output: output);
    output.dependencies.add(
      input.packageRoot.resolve('lib/sources/fanqie/native/fanqie_signature.h'),
    );
  });
}
