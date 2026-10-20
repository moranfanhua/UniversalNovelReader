import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../hook/build.dart' as build_hook;

void main() {
  test(
    'native build hook supports an MSVC installation path containing spaces',
    () async {
      final vswhere = File(
        '${Platform.environment['ProgramFiles(x86)']}'
        '/Microsoft Visual Studio/Installer/vswhere.exe',
      );
      final installation = await Process.run(vswhere.path, [
        '-latest',
        '-products',
        '*',
        '-requires',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '-property',
        'installationPath',
        '-utf8',
      ], stdoutEncoding: utf8);
      expect(installation.exitCode, 0, reason: '${installation.stderr}');
      final installationPath = (installation.stdout as String).trim();
      expect(installationPath, isNotEmpty);
      final version = File(
        '$installationPath/VC/Auxiliary/Build/'
        'Microsoft.VCToolsVersion.default.txt',
      ).readAsStringSync().trim();

      final parent = Directory('.local/native_build_hook_test')
        ..createSync(recursive: true);
      final temporary = parent.createTempSync('build-');
      final compilerAlias = Link('${temporary.absolute.path}/MSVC Tools');
      try {
        // A junction works without the privileges needed for a Windows symlink.
        final junction = await Process.run('cmd.exe', [
          '/c',
          'mklink',
          '/J',
          compilerAlias.path,
          installationPath,
        ]);
        expect(junction.exitCode, 0, reason: '${junction.stderr}');
        final compilerRoot = '${compilerAlias.path}/VC/Tools/MSVC/$version';
        final bin = '$compilerRoot/bin/Hostx64/x64';
        await testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: OS.windows,
          targetArchitecture: Architecture.x64,
          cCompiler: CCompilerConfig(
            compiler: Uri.file('$bin/cl.exe'),
            linker: Uri.file('$bin/link.exe'),
            archiver: Uri.file('$bin/lib.exe'),
            windows: WindowsCCompilerConfig(
              developerCommandPrompt: DeveloperCommandPrompt(
                script: Uri.file(
                  '$installationPath/VC/Auxiliary/Build/vcvars64.bat',
                ),
                arguments: [],
              ),
            ),
          ),
          check: (input, output) {
            final assets = output.assets.code;
            expect(
              assets.map((asset) => asset.id),
              containsAll([
                'package:unr/sources/fanqie/fanqie_signature.dart',
                'package:unr/sources/native_chapter_crypto.dart',
              ]),
            );
            for (final asset in assets) {
              expect(File.fromUri(asset.file!).lengthSync(), greaterThan(0));
            }
          },
        );
      } finally {
        // Remove the junction itself before deleting the temporary directory.
        if (compilerAlias.existsSync()) compilerAlias.deleteSync();
        expect(
          temporary.resolveSymbolicLinksSync(),
          startsWith('${parent.resolveSymbolicLinksSync()}\\'),
        );
        temporary.deleteSync(recursive: true);
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
