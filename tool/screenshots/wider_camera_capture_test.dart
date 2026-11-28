import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_director.dart';
import 'shot_support.dart';
import 'package:kovalink/src/models/road_scene.dart';

void main() {
  testWidgets('wider camera comparison with synthetic objects', (tester) async {
    await tester.runAsync(() async {
      await loadReviewFonts();
      final scene = RoadScene.fromJson({
        'schemaVersion': 2,
        'monotonicTimeNanos': 0,
        'speedMps': 0,
        'plannedPath': [
          for (var x = 0; x <= 120; x += 5) {'x': x, 'y': 0},
        ],
        'leftLane': [
          for (var x = 0; x <= 120; x += 5) {'x': x, 'y': 1.8},
        ],
        'rightLane': [
          for (var x = 0; x <= 120; x += 5) {'x': x, 'y': -1.8},
        ],
        'objects': [
          for (final p in [
            [10, 3.6],
            [18, -3.6],
            [40, 0],
            [-3, 3.6],
          ])
            {'distanceMeters': p[0], 'leftMeters': p[1], 'kind': 'vehicle'},
        ],
      });
      for (final entry in [
        ('portrait', const Size(412, 820)),
        ('landscape', const Size(900, 500)),
      ]) {
        final (name, size) = entry;
        for (final old in [true, false]) {
          final aspect = (size.width / size.height).clamp(.45, 1.8);
          final t = ((aspect - .5) / 1.0).clamp(0.0, 1.0);
          double lerp(double a, double b, double u) => a + (b - a) * u;
          final camera = old
              ? PerspectiveCamera.framed(
                  size,
                  egoWidthFraction: lerp(.36, .205, t),
                  horizonFraction: lerp(.50, .455, t),
                  contactFraction: lerp(.80, .87, t),
                  distance: 8.6,
                )
              : SceneDirector.chaseCamera(size, 0);
          final frame = SceneDirector().update(scene, size);
          await savePainter(
            RoadWorldPainter(
              scene: scene,
              director: DirectorFrame(
                camera: camera,
                rollRadians: frame.rollRadians,
                path: frame.path,
                blindSpots: frame.blindSpots,
                leadTone: frame.leadTone,
              ),
            ),
            size,
            'wide_${name}_${old ? "before" : "after"}',
          );
        }
      }
    });
  });
}
