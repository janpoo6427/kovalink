import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_theme.dart';
import 'package:kovalink/src/gpu_scene/road_world_glb.dart';
import 'package:kovalink/src/gpu_scene/scene_look.dart';
import 'package:kovalink/src/models/ego_vehicle_profile.dart';
import 'package:kovalink/src/models/road_geometry_smoother.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/gateway_controller.dart';

const _xs = [
  0.0,
  3.0,
  6.75,
  12.0,
  18.75,
  27.0,
  36.75,
  48.0,
  60.75,
  75.0,
  90.75,
];

/// Points of a line `y = left + curve·x²` in gateway JSON (schema 2: y left).
List<Map<String, double>> _pts(double left, {double curve = 0}) => [
  for (final x in _xs) {'x': x, 'y': left + curve * x * x},
];

Map<String, dynamic> _frame(
  int ms, {
  double shift = 0,
  double curve = 0,
  List<double> probs = const [0.1, 0.9, 0.9, 0.1],
  int? frameId,
  List<double> edgeStds = const [0.5, 0.5],
  bool geometry = true,
}) => {
  'schemaVersion': 2,
  'monotonicTimeNanos': ms * 1000000,
  'speedMps': 20,
  'modelFrameId': ?frameId,
  if (geometry) ...{
    'plannedPath': _pts(shift, curve: curve),
    'laneLines': [
      for (var i = 0; i < 4; i++)
        if (probs[i] >= 0.2)
          {
            'index': i,
            'probability': probs[i],
            'points': _pts(shift + [5.3, 1.8, -1.7, -5.2][i], curve: curve),
          },
    ],
    'roadEdges': [
      _pts(shift + 7, curve: curve),
      _pts(shift - 6.9, curve: curve),
    ],
    'roadEdgeStds': edgeStds,
  },
};

RoadScene _parse(Map<String, dynamic> json) =>
    RoadScene.fromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);

LaneLine? _lane(RoadScene scene, int index) {
  for (final line in scene.laneLines) {
    if (line.index == index) return line;
  }
  return null;
}

double _at(List<ScenePoint> points, double x) =>
    RoadScene.interpolateLeft(points, x);

void main() {
  group('telemetry parsing', () {
    test('schema 1 frames (model y points right) are mirrored', () {
      final v1 = _parse({
        'schemaVersion': 1,
        'monotonicTimeNanos': 1,
        'speedMps': 10,
        'plannedPath': [
          {'x': 0, 'y': 0, 'z': 1.2},
          {'x': 50, 'y': -4, 'z': 1.2},
        ],
        'leftLane': [
          {'x': 0, 'y': -1.8, 'z': 1.2},
          {'x': 50, 'y': -5.8, 'z': 1.2},
        ],
      });
      // A left curve: openpilot y < 0, this app's left is positive.
      expect(v1.plannedPath.last.leftMeters, 4);
      expect(v1.leftLane.first.leftMeters, 1.8);
      expect(v1.plannedPath.last.upMeters, -1.2);

      final v2 = _parse({
        'schemaVersion': 2,
        'monotonicTimeNanos': 1,
        'speedMps': 10,
        'plannedPath': [
          {'x': 0, 'y': 0},
          {'x': 50, 'y': 4},
        ],
      });
      expect(v2.plannedPath.last.leftMeters, 4);
    });

    test('malformed points are dropped instead of failing the frame', () {
      final scene = _parse({
        'schemaVersion': 2,
        'monotonicTimeNanos': 1,
        'speedMps': 10,
        'plannedPath': [
          {'x': 0, 'y': 0},
          {'x': 'bad', 'y': 1},
          {'x': 5},
          null,
          7,
          {'x': 10, 'y': 0.5},
          {'x': 8, 'y': 9}, // folds back: dropped
          {'x': 20, 'y': 1e9}, // absurd: dropped
          {'x': 30, 'y': 1.5},
        ],
        'laneLines': [
          'not a line',
          {
            'index': 1,
            'probability': 7,
            'points': [
              {'x': 0, 'y': 1.8},
              {'x': 10, 'y': 1.9},
            ],
          },
          {'index': 9, 'points': 'nope'},
        ],
        'roadEdges': [
          [
            {'x': 0, 'y': 7},
          ],
          'x',
        ],
        'roadEdgeStds': ['a', 0.4],
      });
      expect(scene.plannedPath.map((p) => p.forwardMeters), [0, 10, 30]);
      expect(scene.laneLines, hasLength(2));
      expect(scene.laneLines.first.index, 1);
      expect(scene.laneLines.first.probability, 1);
      expect(scene.laneLines.last.index, isNull);
      expect(scene.laneLines.last.points, isEmpty);
      expect(scene.roadEdges.last, isEmpty);
      expect(scene.roadEdgeStds, [double.infinity, 0.4]);
    });
  });

  group('geometry smoothing', () {
    test('a small lateral step is eased, a lane-width jump restarts', () {
      final s = RoadGeometrySmoother();
      var out = s.apply(_parse(_frame(0)));
      expect(_at(out.plannedPath, 20), closeTo(0, 1e-9));
      out = s.apply(_parse(_frame(50, shift: 0.5)));
      final eased = _at(out.plannedPath, 20);
      expect(eased, greaterThan(0.01));
      expect(eased, lessThan(0.4));
      // Several frames later it has followed the step (the alpha-beta
      // filter may overshoot a hard step a little on the way).
      for (var t = 100; t <= 3000; t += 50) {
        out = s.apply(_parse(_frame(t, shift: 0.5)));
      }
      expect(_at(out.plannedPath, 20), closeTo(0.5, 0.05));
      // A lane change: everything jumps by a lane width -> no slow slide.
      out = s.apply(_parse(_frame(3050, shift: 4.1)));
      expect(_at(out.plannedPath, 20), closeTo(4.1, 1e-6));
    });

    test('one spiky frame far ahead moves the line only a little', () {
      final s = RoadGeometrySmoother();
      for (var t = 0; t <= 500; t += 50) {
        s.apply(_parse(_frame(t)));
      }
      final spike = _frame(550);
      final path = (spike['plannedPath'] as List).cast<Map<String, double>>();
      path[path.length - 2] = {'x': 75.0, 'y': 40.0};
      final out = s.apply(_parse(spike));
      expect(_at(out.plannedPath, 75).abs(), lessThan(40 * 0.12));
    });

    test('ego lane lines use show/hide hysteresis and fade', () {
      final s = RoadGeometrySmoother();
      var out = s.apply(_parse(_frame(0, probs: [0.1, 0.4, 0.9, 0.1])));
      expect(_lane(out, 1)?.fade, 1, reason: 'first frame snaps');
      // 0.25 is below "show" (0.35) but above "hide" (0.2): stays.
      out = s.apply(_parse(_frame(50, probs: [0.1, 0.25, 0.9, 0.1])));
      expect(_lane(out, 1)?.fade, 1);
      // Gone from the frame (gateway drops < 0.2): fades out, no pop.
      out = s.apply(_parse(_frame(100, probs: [0.1, 0.1, 0.9, 0.1])));
      final fading = _lane(out, 1)!.fade;
      expect(fading, inExclusiveRange(0.0, 1.0));
      for (var t = 150; t <= 600; t += 50) {
        out = s.apply(_parse(_frame(t, probs: [0.1, 0.1, 0.9, 0.1])));
      }
      expect(_lane(out, 1), isNull);
      // 0.3 does not bring it back (needs 0.35).
      out = s.apply(_parse(_frame(650, probs: [0.1, 0.3, 0.9, 0.1])));
      expect(_lane(out, 1), isNull);
      out = s.apply(_parse(_frame(700, probs: [0.1, 0.4, 0.9, 0.1])));
      expect(_lane(out, 1)!.fade, closeTo(0.05 / 0.35, 1e-6));
    });

    test('outer lanes need a plausible lane width', () {
      final s = RoadGeometrySmoother();
      final ok = s.apply(_parse(_frame(0, probs: [0.9, 0.9, 0.9, 0.9])));
      expect(_lane(ok, 0), isNotNull);
      expect(_lane(ok, 3), isNotNull);
      final narrow = _frame(5000 + 50, probs: [0.9, 0.9, 0.9, 0.9]);
      final s2 = RoadGeometrySmoother();
      final lanes = (narrow['laneLines'] as List).cast<Map<String, dynamic>>();
      lanes[0]['points'] = _pts(2.6); // 0.8 m from the ego left line
      final out = s2.apply(_parse(narrow));
      expect(_lane(out, 0), isNull);
      expect(_lane(out, 1), isNotNull);
    });

    test('a repeated model frame does not step the filters', () {
      final s = RoadGeometrySmoother();
      s.apply(_parse(_frame(0, frameId: 1)));
      final a = s.apply(_parse(_frame(50, frameId: 2, shift: 0.5)));
      final b = s.apply(_parse(_frame(100, frameId: 2, shift: 0.5)));
      expect(_at(b.plannedPath, 20), _at(a.plannedPath, 20));
    });

    test('late frames keep the last geometry briefly, then clear', () {
      final s = RoadGeometrySmoother();
      s.apply(_parse(_frame(0)));
      var out = s.apply(_parse(_frame(300, geometry: false)));
      expect(out.plannedPath, isNotEmpty);
      expect(out.laneLines, isNotEmpty);
      out = s.apply(_parse(_frame(600, geometry: false)));
      expect(out.plannedPath, isEmpty);
      expect(out.laneLines, isEmpty);
      expect(out.roadEdges, isEmpty);
    });

    test('a path folding sideways is cut where it turns too hard', () {
      final s = RoadGeometrySmoother();
      final frame = _frame(0);
      frame['plannedPath'] = [
        for (final x in _xs)
          {'x': x, 'y': x < 40 ? 0.02 * x * x : 32.0 + (x - 40) * 6},
      ];
      final out = s.apply(_parse(frame));
      expect(out.plannedPath.last.forwardMeters, lessThanOrEqualTo(48));
      for (var i = 1; i < out.plannedPath.length; i++) {
        final a = out.plannedPath[i - 1], b = out.plannedPath[i];
        expect(
          (b.leftMeters - a.leftMeters).abs() /
              (b.forwardMeters - a.forwardMeters),
          lessThan(4),
        );
      }
    });

    test('the road boundary blends when an edge becomes unsure', () {
      final s = RoadGeometrySmoother();
      var out = s.apply(_parse(_frame(0)));
      expect(_at(out.roadEdges.first, 10), closeTo(7, 1e-6));
      // Left edge unsure: boundary heads to the outer lane (5.3 + 0.6)...
      out = s.apply(
        _parse(_frame(50, edgeStds: [3, 0.5], probs: [0.9, 0.9, 0.9, 0.1])),
      );
      final mid = _at(out.roadEdges.first, 10);
      expect(mid, lessThan(7));
      expect(mid, greaterThan(5.9));
      for (var t = 100; t <= 1000; t += 50) {
        out = s.apply(
          _parse(_frame(t, edgeStds: [3, 0.5], probs: [0.9, 0.9, 0.9, 0.1])),
        );
      }
      expect(_at(out.roadEdges.first, 10), closeTo(5.9, 0.05));
    });

    test('lines of different lengths and empty arrays are fine', () {
      final s = RoadGeometrySmoother();
      final frame = _frame(0);
      final lanes = (frame['laneLines'] as List).cast<Map<String, dynamic>>();
      lanes[0]['points'] = _pts(1.8).sublist(0, 3);
      lanes[1]['points'] = <Object>[];
      frame['plannedPath'] = <Object>[];
      final out = s.apply(_parse(frame));
      expect(out.plannedPath, isEmpty);
      expect(_lane(out, 1)?.points.last.forwardMeters, 6.75);
      expect(_lane(out, 2), isNull);
    });
  });

  group('perspective and curvature', () {
    test('ribbon offsets are measured across the line direction', () {
      double diagonal(double x) => x; // 45 degrees
      final (px, py) = RoadWorldPainter.normalOffset(diagonal, 10, 1);
      // Distance from the line y = x is |py - px| / sqrt(2).
      expect((py - px).abs() / math.sqrt2, closeTo(1, 1e-9));
      final (sx, sy) = RoadWorldPainter.normalOffset((x) => 2.0, 10, -0.5);
      expect(sx, 10);
      expect(sy, 1.5);
    });

    test('a left curve from the comma is drawn bending left', () {
      // Raw openpilot frame (schema 1): a left curve has negative y.
      final scene = RoadGeometrySmoother().apply(
        _parse({
          'schemaVersion': 1,
          'monotonicTimeNanos': 1,
          'speedMps': 15,
          'plannedPath': [
            for (final x in _xs) {'x': x, 'y': -0.004 * x * x, 'z': 1.2},
          ],
        }),
      );
      const size = Size(800, 480);
      final camera = SceneCamera.forViewpoint(
        SceneViewpoint.chase,
        size,
        EgoVehicleProfile.builtIn,
      );
      final near = camera.project(V3(10, scene.pathLeftAt(10), 0))!;
      final far = camera.project(V3(60, scene.pathLeftAt(60), 0))!;
      expect(far.offset.dx, lessThan(near.offset.dx - 20));
    });
  });

  group('bad data never breaks the view', () {
    Future<ui.Image> render(RoadScene scene) {
      final recorder = ui.PictureRecorder();
      RoadWorldPainter(
        scene: scene,
      ).paint(Canvas(recorder), const Size(400, 240));
      return recorder.endRecording().toImage(400, 240);
    }

    final bad = <Map<String, dynamic>>[
      _frame(0),
      _frame(50, geometry: false),
      {..._frame(100), 'plannedPath': <Object>[]},
      {..._frame(150), 'laneLines': 'x', 'roadEdges': null},
      {
        ..._frame(200),
        'plannedPath': [
          {'x': 0, 'y': 0},
          {'x': 1, 'y': 900},
        ],
      },
      {..._frame(250), 'roadEdgeStds': <Object>[]},
      _frame(10250, shift: 30, curve: 0.02),
      {..._frame(10300), 'monotonicTimeNanos': 5},
    ];

    test('software and GPU scene builders take every frame', () async {
      final s = RoadGeometrySmoother();
      for (final json in bad) {
        final scene = s.apply(_parse(json));
        await render(scene);
        RoadWorldGlb.build(
          scene,
          SceneLook.resolve(SceneTheme.clear, scene.roadType),
        );
      }
    });

    test('live controller keeps drawing through bad frames', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final ws = await WebSocketTransformer.upgrade(request);
        for (final json in bad) {
          ws.add(jsonEncode(json));
        }
        ws.add('{"broken json');
        ws.add(jsonEncode(_frame(10400)));
      });
      final controller = GatewayController();
      addTearDown(() async {
        controller.dispose();
        await server.close(force: true);
      });
      final scenes = <RoadScene>[];
      controller.addListener(() => scenes.add(controller.scene));
      expect(
        await controller.connect('ws://127.0.0.1:${server.port}/v1/telemetry'),
        isNull,
      );
      for (var i = 0; i < 50 && scenes.length < bad.length + 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(scenes.length, greaterThanOrEqualTo(bad.length + 2));
      for (final scene in scenes) {
        await render(scene);
      }
      expect(controller.mode, GatewayMode.live);
      expect(controller.scene.plannedPath, isNotEmpty);
    });
  });
}
