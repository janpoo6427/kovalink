import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/models/road_scene.dart';

void main() {
  test('parses a typed road scene', () {
    final scene = RoadScene.fromJson({
      'monotonicTimeNanos': 42,
      'speedMps': 10,
      'setSpeedMps': 12,
      'steeringAngleDegrees': -1.5,
      'engaged': true,
      'gear': 'drive',
      'leftBlinker': true,
      'brakeActive': true,
      'speedLimitKph': 80,
      'tbt': {
        'maneuver': 'turnLeft',
        'distanceMeters': 420,
        'roadName': '테스트 교차로',
      },
      'plannedPath': [
        {'x': 0, 'y': 0},
        {'x': 10, 'y': 0.2},
      ],
      'leftLane': <Object>[],
      'rightLane': <Object>[],
      'objects': [
        {
          'distanceMeters': 25,
          'leftMeters': 0.1,
          'relativeSpeedMps': -1,
          'kind': 'vehicle',
        },
      ],
      'cameraProjection': {
        'matrix3x4': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0],
        'sourceWidth': 1928,
        'sourceHeight': 1208,
      },
    });
    expect(scene.speedKph, 36);
    expect(scene.plannedPath, hasLength(2));
    expect(scene.objects.single.kind, TrackedObjectKind.vehicle);
    expect(scene.cameraProjection?.matrix, hasLength(12));
    expect(scene.gear, VehicleGear.drive);
    expect(scene.leftBlinker, isTrue);
    expect(scene.brakeActive, isTrue);
    expect(scene.speedLimitKph, 80);
    expect(scene.tbt?.maneuver, TbtManeuver.turnLeft);
  });
}
