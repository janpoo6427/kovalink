// Command-line helper for vehicle model pack authors.
//
//   dart run tool/kovamodel.dart pack <pack-folder> <out.kovamodel>
//   dart run tool/kovamodel.dart check <file.kovamodel>
//
// `check` runs exactly the validator the app uses on import. Neither command
// uses the network or executes anything from the pack.
import 'dart:io';

import 'package:kovalink/src/vehicle_pack/model_pack_validator.dart';
import 'package:kovalink/src/vehicle_pack/zip_writer.dart';

void main(List<String> args) {
  if (args.length == 3 && args[0] == 'pack') {
    final files = Directory(args[1]).listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final archive = ZipWriter.build([
      for (final file in files)
        if (!file.uri.pathSegments.last.startsWith('.'))
          ZipWriterEntry(file.uri.pathSegments.last, file.readAsBytesSync()),
    ]);
    File(args[2]).writeAsBytesSync(archive);
    stdout.writeln('wrote ${args[2]} (${archive.length} bytes)');
    exitCode = _check(args[2]);
    return;
  }
  if (args.length == 2 && args[0] == 'check') {
    exitCode = _check(args[1]);
    return;
  }
  stderr.writeln(
    'usage: dart run tool/kovamodel.dart pack <folder> <out.kovamodel>\n'
    '       dart run tool/kovamodel.dart check <file.kovamodel>',
  );
  exitCode = 64;
}

int _check(String path) {
  final result = ModelPackValidator.validate(File(path).readAsBytesSync());
  final rejection = result.rejection;
  if (rejection != null) {
    stdout.writeln('REJECTED ${rejection.code}: ${rejection.message}');
    return 1;
  }
  final manifest = result.manifest!;
  final glb = result.glb!;
  stdout.writeln(
    'OK ${manifest.id} "${manifest.displayName}" by ${manifest.author} '
    '(${manifest.license}); ${glb.triangles} triangles, '
    'max texture ${glb.maxTextureSize}px',
  );
  for (final warning in result.warnings) {
    stdout.writeln('WARNING $warning');
  }
  return 0;
}
