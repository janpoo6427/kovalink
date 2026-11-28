import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/vehicle_mesh_painter.dart';
import 'package:kovalink/src/models/ego_vehicle_profile.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/models/vehicle_model_manifest.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/vehicle_mesh/builtin_vehicles.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh_loader.dart';

List<ScenePoint> _line(double left) => [
  for (var x = 0.0; x <= 160; x += 10)
    ScenePoint(forwardMeters: x, leftMeters: left),
];

RoadScene _scene({
  List<TrackedObject> objects = const [],
  bool brake = false,
  bool left = false,
  int timeNanos = 0,
}) => RoadScene(
  monotonicTimeNanos: timeNanos,
  speedMps: 25,
  setSpeedMps: 27,
  steeringAngleDegrees: 0,
  engaged: true,
  brakeActive: brake,
  leftBlinker: left,
  plannedPath: _line(0),
  leftLane: const [],
  rightLane: const [],
  laneLines: [
    LaneLine(points: _line(1.8)),
    LaneLine(points: _line(-1.8)),
  ],
  roadEdges: [_line(5.4), _line(-5.4)],
  objects: objects,
);

Future<ui.Image> _render(CustomPainter painter, Size size) {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  return recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
}

Future<Color> _pixel(ui.Image image, Offset at) async {
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final x = at.dx.round().clamp(0, image.width - 1);
  final y = at.dy.round().clamp(0, image.height - 1);
  final o = (y * image.width + x) * 4;
  return Color.fromARGB(
    255,
    data.getUint8(o),
    data.getUint8(o + 1),
    data.getUint8(o + 2),
  );
}

int _c(double channel) => (channel * 255).round();

/// Screen box of a vehicle-sized box (length × width × height, plus
/// mirror allowance) at its pose: the mesh must lie inside it.
Rect _boxProjection(
  SceneCamera camera,
  VehiclePose pose, {
  double mirrors = 0.32,
}) {
  final pts = <Offset>[];
  final c = math.cos(pose.yaw), s = math.sin(pose.yaw);
  final cx = pose.rearX + pose.length / 2;
  for (final dx in [-pose.length / 2 - 0.02, pose.length / 2 + 0.02]) {
    for (final dy in [
      -(pose.width + mirrors) / 2,
      (pose.width + mirrors) / 2,
    ]) {
      for (final z in [0.0, pose.height + 0.02]) {
        final p = camera.project(
          V3(cx + c * dx - s * dy, pose.leftY + s * dx + c * dy, z),
        );
        if (p != null) pts.add(p.offset);
      }
    }
  }
  final xs = pts.map((p) => p.dx), ys = pts.map((p) => p.dy);
  return Rect.fromLTRB(
    xs.reduce(math.min),
    ys.reduce(math.min),
    xs.reduce(math.max),
    ys.reduce(math.max),
  );
}

void main() {
  group('size and perspective', () {
    for (final size in const [
      Size(1200, 945),
      Size(1080, 2340),
      Size(1081, 1200),
    ]) {
      test('chase camera is a realistic pinhole for $size', () {
        final camera = PerspectiveCamera.chase(size);
        final fov = camera.horizontalFov(size.width) * 180 / math.pi;
        expect(fov, inInclusiveRange(45, 80));
        expect(
          camera.eye.z,
          inInclusiveRange(1.8, 7.5 / PerspectiveCamera.chaseFramingScale),
          reason: 'camera height (m)',
        );
        // f · W / D holds exactly for a 1.85 m wide car at every distance.
        for (final d in const [5.0, 20.0, 60.0]) {
          final l = camera.project(V3(d, 0.925, 0))!;
          final r = camera.project(V3(d, -0.925, 0))!;
          expect(
            r.offset.dx - l.offset.dx,
            closeTo(camera.focalPixels * 1.85 / l.depth, 1e-6),
          );
        }
      });
    }

    test('every vehicle in the highway demo fits its real-size box', () {
      const size = Size(1200, 945);
      final camera = PerspectiveCamera.chase(size);
      final scene = DemoDriveScenario(
        route: DemoRoute.highway,
      ).sceneAt(const Duration(seconds: 75));
      final drawn = <(TrackedObject?, VehiclePose, MeshDrawStats)>[];
      RoadWorldPainter(
        scene: scene,
        vehicle: VehicleModelLoadResult.bundledDefault.profile,
        onVehicleDrawn: (o, p, s) => drawn.add((o, p, s)),
      ).paint(Canvas(ui.PictureRecorder()), size);
      expect(drawn.length, greaterThanOrEqualTo(4));
      for (final (object, pose, stats) in drawn) {
        if (stats.trianglesDrawn == 0) continue;
        final box = _boxProjection(camera, pose).inflate(2);
        expect(
          box.contains(stats.bounds.topLeft) &&
              box.contains(stats.bounds.bottomRight),
          isTrue,
          reason:
              '${object?.kind ?? 'ego'} at ${pose.rearX.toStringAsFixed(1)} m: ${stats.bounds} vs $box',
        );
        // And it is not drawn much smaller than its size either.
        expect(stats.bounds.height, greaterThan(box.height * 0.6));
        // Real sizes, not the drawing defaults: trucks 3.2 m, cars < 1.8 m.
        if (object?.kind == TrackedObjectKind.truck) {
          expect(pose.height, closeTo(3.2, 1e-9));
        } else {
          expect(pose.height, lessThan(1.8));
        }
      }
    });

    test('a 1.85 m car is drawn 1.85 m wide (top view is metric)', () async {
      const size = Size(600, 900);
      final camera = TopDownCamera(size);
      const object = TrackedObject(
        distanceMeters: 10,
        leftMeters: 0,
        relativeSpeedMps: 0,
        lengthMeters: 4.6,
        widthMeters: 1.85,
        heightMeters: 1.45,
      );
      final drawn = <MeshDrawStats>[];
      RoadWorldPainter(
        scene: _scene(objects: const [object]),
        viewpoint: SceneViewpoint.topDown,
        layers: const SceneLayers(scenery: false),
        onVehicleDrawn: (o, p, s) {
          if (o != null) drawn.add(s);
        },
      ).paint(Canvas(ui.PictureRecorder()), size);
      final bounds = drawn.single.bounds;
      expect(bounds.height, closeTo(4.6 * camera.scale, camera.scale * 0.12));
      // Width including mirrors: body 1.85 m + mirrors < 0.35 m.
      expect(
        bounds.width,
        inInclusiveRange(1.85 * camera.scale, 2.2 * camera.scale),
      );
    });

    test('ego and a car beside it at the same gap scale with their sizes', () {
      const size = Size(1200, 945);
      final drawn = <TrackedObject?, MeshDrawStats>{};
      const truck = TrackedObject(
        distanceMeters: -4.5,
        leftMeters: -3.6,
        relativeSpeedMps: 0,
        kind: TrackedObjectKind.truck,
      );
      RoadWorldPainter(
        scene: _scene(objects: const [truck]),
        vehicle: VehicleModelLoadResult.bundledDefault.profile,
        layers: const SceneLayers(scenery: false),
        onVehicleDrawn: (o, p, s) => drawn[o] = s,
      ).paint(Canvas(ui.PictureRecorder()), size);
      final ego = drawn[null]!.bounds, other = drawn[truck]!.bounds;
      // Same rear gap: heights relate like 3.2 m : 1.69 m (± perspective).
      expect(other.height / ego.height, inInclusiveRange(1.4, 2.4));
    });
  });

  group('mesh vehicle painting', () {
    test('brake and turn lamps light up; plate stays white', () async {
      const size = Size(800, 700);
      final camera = PerspectiveCamera.chase(size);
      const profile = EgoVehicleProfile.builtIn;
      final rear = -profile.dimensions.length;
      Future<ui.Image> draw({bool brake = false, bool left = false}) => _render(
        RoadWorldPainter(
          scene: _scene(brake: brake, left: left),
          layers: const SceneLayers(scenery: false, path: false),
        ),
        size,
      );
      final scaleZ = profile.dimensions.height / BuiltinVehicles.suv.size.$3;
      final scaleY = profile.dimensions.width / BuiltinVehicles.suv.size.$2;
      Offset at(double y, double z) =>
          camera.project(V3(rear - 0.01, y * scaleY, z * scaleZ))!.offset;
      final off = await draw();
      final on = await draw(brake: true);
      final lampOff = await _pixel(off, at(0.77, 0.76));
      final lampOn = await _pixel(on, at(0.77, 0.76));
      expect(_c(lampOn.r), greaterThan(_c(lampOff.r) + 40));
      expect(_c(lampOn.r), greaterThan(_c(lampOn.g) + 120));
      final plate = await _pixel(off, at(0, 0.555));
      expect(_c(plate.r), greaterThan(170));
      expect((_c(plate.r) - _c(plate.b)).abs(), lessThan(30));
      final blink = await draw(left: true);
      final amber = await _pixel(blink, at(0.68, 0.87));
      expect(_c(amber.r), greaterThan(200));
      expect(
        _c(amber.g),
        greaterThan(_c(amber.b) + 60),
        reason: 'amber, not red',
      );
    });

    test('far vehicles use the simpler levels', () {
      const size = Size(1200, 945);
      final drawn = <TrackedObject?, MeshDrawStats>{};
      const near = TrackedObject(
        distanceMeters: 0,
        leftMeters: 0,
        relativeSpeedMps: 0,
      );
      const far = TrackedObject(
        distanceMeters: 120,
        leftMeters: 0.5,
        relativeSpeedMps: 0,
      );
      RoadWorldPainter(
        scene: _scene(objects: const [near, far]),
        layers: const SceneLayers(scenery: false),
        onVehicleDrawn: (o, p, s) => drawn[o] = s,
      ).paint(Canvas(ui.PictureRecorder()), size);
      expect(
        drawn[near]!.trianglesIn,
        BuiltinVehicles.sedanSet.lod0.triangleCount,
      );
      expect(
        drawn[far]!.trianglesIn,
        BuiltinVehicles.sedanSet.lod2.triangleCount,
      );
    });

    test('imported ToyCar pack renders through the mesh pipeline', () async {
      final manifest = VehicleModelManifest.fromJson(
        await _json('assets/vehicles/toy_car/vehicle.json'),
      );
      final bytes = File(
        'assets/vehicles/toy_car/vehicle.glb',
      ).readAsBytesSync();
      final load = await VehicleMeshLoader.fromBytes(
        bytes,
        manifest,
        background: false,
      );
      expect(load.mesh, isNotNull, reason: load.warnings.join('\n'));
      expect(load.warnings.join(), contains('단순화'));
      expect(load.mesh!.lod0.colors, isNotNull, reason: 'texture baked');
      final drawn = <MeshDrawStats>[];
      RoadWorldPainter(
        scene: _scene(),
        vehicle: EgoVehicleProfile.fromManifest(manifest),
        egoMesh: load.mesh,
        onVehicleDrawn: (o, p, s) {
          if (o == null) drawn.add(s);
        },
      ).paint(Canvas(ui.PictureRecorder()), const Size(1200, 945));
      expect(drawn.single.trianglesIn, load.mesh!.lod0.triangleCount);
      expect(drawn.single.trianglesDrawn, greaterThan(500));
    });
  });

  group('frame cost', () {
    test('ego + 12 cars: worker CPU benchmark', () async {
      const size = Size(1200, 945);
      final objects = [
        for (var i = 0; i < 12; i++)
          TrackedObject(
            id: i,
            distanceMeters: 8.0 + i * 11,
            leftMeters: (i % 3 - 1) * 3.6,
            relativeSpeedMps: 0,
            kind: i == 5 ? TrackedObjectKind.truck : TrackedObjectKind.vehicle,
          ),
      ];
      final painter = RoadWorldPainter(
        scene: _scene(objects: objects, brake: true),
      );
      var triangles = 0;
      final meshOnly = RoadWorldPainter(
        scene: _scene(objects: objects, brake: true),
        layers: const SceneLayers(scenery: false, lanes: false, path: false),
        onVehicleDrawn: (o, p, s) => triangles += s.trianglesDrawn,
      );
      // Warm up (mesh generation, JIT).
      for (var i = 0; i < 5; i++) {
        painter.paint(Canvas(ui.PictureRecorder()), size);
      }
      const frames = 40;
      final record = Stopwatch()..start();
      for (var i = 0; i < frames; i++) {
        painter.paint(Canvas(ui.PictureRecorder()), size);
      }
      record.stop();
      final bare = RoadWorldPainter(
        scene: _scene(),
        layers: const SceneLayers(objects: false),
      );
      final roadOnly = Stopwatch()..start();
      for (var i = 0; i < frames; i++) {
        bare.paint(Canvas(ui.PictureRecorder()), size);
      }
      roadOnly.stop();
      triangles = 0;
      meshOnly.paint(Canvas(ui.PictureRecorder()), size);
      final raster = Stopwatch();
      for (var i = 0; i < 5; i++) {
        final recorder = ui.PictureRecorder();
        painter.paint(Canvas(recorder), size);
        final picture = recorder.endRecording();
        raster.start();
        final image = await picture.toImage(
          size.width.toInt(),
          size.height.toInt(),
        );
        await image.toByteData();
        raster.stop();
        image.dispose();
      }
      final perFrame = record.elapsedMicroseconds / frames / 1000;
      final rasterMs = raster.elapsedMicroseconds / 5 / 1000;
      // ignore: avoid_print
      print(
        'KOVA_PERF scene+13 vehicles: record ${perFrame.toStringAsFixed(2)} ms/frame '
        '(road+scenery+ego without other cars ${(roadOnly.elapsedMicroseconds / frames / 1000).toStringAsFixed(2)} ms), '
        'raster(software) ${rasterMs.toStringAsFixed(1)} ms/frame, '
        'vehicle triangles drawn $triangles',
      );
      expect(
        perFrame,
        lessThan(40),
        reason: 'CPU side of one frame on the worker',
      );
      expect(triangles, lessThan(9000));
    });
  });
}

Future<Map<String, dynamic>> _json(String path) async =>
    jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
