import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/models/road_scene.dart';

// A telemetry frame as the kovapilot gateway sends it with radar vehicles
// (kovapilot/gateway/radar_objects.py).
List<Map<String, dynamic>> _points(double left) => [
  for (var x = 0.0; x <= 120; x += 10) {'x': x, 'y': left},
];

Map<String, dynamic> _frame(List<Map<String, dynamic>> objects) => {
  'schemaVersion': 2,
  'monotonicTimeNanos': 0,
  'speedMps': 25,
  'gear': 'drive',
  'engaged': true,
  'plannedPath': _points(0),
  'laneLines': [
    {'index': 0, 'probability': 0.6, 'points': _points(5.4)},
    {'index': 1, 'probability': 0.9, 'points': _points(1.8)},
    {'index': 2, 'probability': 0.9, 'points': _points(-1.8)},
    {'index': 3, 'probability': 0.6, 'points': _points(-5.4)},
  ],
  'objects': objects,
};

Map<String, dynamic> _vehicle(
  int id,
  double distance,
  double left,
  String lane, {
  bool isLead = false,
  bool moving = true,
}) => {
  'id': id,
  'kind': 'vehicle',
  'distanceMeters': distance,
  'leftMeters': left,
  'relativeSpeedMps': -1.0,
  'lane': lane,
  'moving': moving,
  'isLead': isLead,
};

Future<ui.Image> _render(CustomPainter painter, Size size) {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  return recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
}

Future<Color> _pixel(ui.Image image, Offset at) async {
  final bytes = (await image.toByteData())!;
  final index = (at.dy.round() * image.width + at.dx.round()) * 4;
  return Color.fromARGB(
    bytes.getUint8(index + 3),
    bytes.getUint8(index),
    bytes.getUint8(index + 1),
    bytes.getUint8(index + 2),
  );
}

int _c(double channel) => (channel * 255).round();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses kovapilot radar vehicles with lane and moving', () {
    final scene = RoadScene.fromJson(
      _frame([
        _vehicle(11, 22, 0.1, 'ego', isLead: true, moving: false),
        _vehicle(5, 12.3, 3.8, 'left'),
        _vehicle(9, 25, -3.7, 'right'),
        {'distanceMeters': 30, 'leftMeters': 0, 'lane': 'middle'},
      ]),
    );
    final objects = scene.objects;
    expect(objects.map((o) => o.lane), [
      TrackedObjectLane.ego,
      TrackedObjectLane.left,
      TrackedObjectLane.right,
      null,
    ], reason: 'an unknown lane name is no lane');
    expect(objects.map((o) => o.moving), [false, true, true, null]);
    expect(objects.map((o) => o.id), [11, 5, 9, null]);
    expect(objects[1].distanceMeters, 12.3);
    expect(objects[1].leftMeters, 3.8);
    expect(objects[1].relativeSpeedMps, -1.0);
    expect(objects[1].kind, TrackedObjectKind.vehicle);
    expect(scene.leadObject, same(objects.first));
  });

  test('radar vehicles without a marked lead show no lead', () {
    // an own lane radar vehicle the car does not follow stays a vehicle
    final scene = RoadScene.fromJson(
      _frame([_vehicle(4, 18, 0.3, 'ego'), _vehicle(5, 12, 3.8, 'left')]),
    );
    expect(scene.objects, hasLength(2));
    expect(scene.leadObject, isNull);
  });

  test('objects without a lane keep the path corridor lead', () {
    final scene = RoadScene.fromJson(
      _frame([
        {'distanceMeters': 30, 'leftMeters': 0.2, 'kind': 'vehicle'},
      ]),
    );
    expect(scene.leadObject, same(scene.objects.single));
  });

  test('road view draws the radar lead blue and side lane vehicles light', () async {
    const size = Size(600, 800);
    final scene = RoadScene.fromJson(
      _frame([
        _vehicle(11, 22, 0, 'ego', isLead: true),
        _vehicle(9, 26, -3.6, 'right'),
      ]),
    );
    final image = await _render(
      RoadWorldPainter(
        scene: scene,
        layers: const SceneLayers(scenery: false),
      ),
      size,
    );
    final camera = PerspectiveCamera.chase(size);
    final lead = await _pixel(
      image,
      camera.project(const V3(22, 0, 0.55))!.offset,
    );
    expect(_c(lead.b) - _c(lead.r), greaterThan(40), reason: 'lead is blue');
    final side = await _pixel(
      image,
      camera.project(const V3(26, -3.6, 0.55))!.offset,
    );
    expect(_c(side.r), greaterThan(150), reason: 'side vehicle is light');
    expect((_c(side.b) - _c(side.r)).abs(), lessThan(40));
  });
}
