import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/models/vehicle_model_manifest.dart';

void main() {
  test('parses vehicle model pack v1 bindings', () {
    final manifest = VehicleModelManifest.fromJson({
      'schemaVersion': 1,
      'id': 'test-car',
      'displayName': 'Test Car',
      'asset': 'vehicle.glb',
      'coordinateSystem': 'RH_Y_UP_Z_FORWARD',
      'dimensionsMeters': {
        'length': 5,
        'width': 2,
        'height': 1.7,
        'wheelbase': 3,
      },
      'nodes': {
        'body': 'Body',
        'brakeLights': ['BrakeL', 'BrakeR'],
      },
      'cameras': {
        'drive': {
          'position': [0, 1.2, 3.2],
          'target': [0, 0.3, 0],
        },
      },
    });

    expect(manifest.id, 'test-car');
    expect(manifest.dimensions.wheelbase, 3);
    expect(manifest.nodes.brakeLights, ['BrakeL', 'BrakeR']);
    expect(manifest.cameras['drive']?.position, [0, 1.2, 3.2]);
  });

  test('rejects unsupported vehicle model schema', () {
    expect(
      () => VehicleModelManifest.fromJson({'schemaVersion': 2}),
      throwsFormatException,
    );
  });
}
