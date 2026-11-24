// Regenerates the KovaLink basic example vehicle from code:
//
//   dart run tool/make_builtin_vehicles.dart [out.glb]
//
// Writes assets/vehicles/kovalink_basic/vehicle.glb (CC0-1.0, KovaLink
// project) from BuiltinVehicles.suv — the same mesh the app draws when no
// pack GLB is available. Output is deterministic.
import 'dart:io';

import 'package:kovalink/src/vehicle_mesh/builtin_vehicles.dart';
import 'package:kovalink/src/vehicle_mesh/glb_writer.dart';

void main(List<String> args) {
  final out = args.isEmpty
      ? 'assets/vehicles/kovalink_basic/vehicle.glb'
      : args.first;
  final builder = BuiltinVehicles.builderFor(BuiltinBody.suv);
  final bytes = GlbWriter.write(
    builder,
    rearAxleX: BuiltinVehicles.suvRearAxleX,
  );
  File(out).writeAsBytesSync(bytes);
  stdout.writeln(
    'wrote $out (${bytes.length} bytes, ${builder.triangleCount} triangles)',
  );
}
