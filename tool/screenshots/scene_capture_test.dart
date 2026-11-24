import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/models/road_scene.dart';

import 'shot_support.dart';

List<ScenePoint> _line(double left, double curve) => [
  for (var x = 0.0; x <= 160; x += 8)
    ScenePoint(forwardMeters: x, leftMeters: left + curve * x * x),
];

RoadScene _scene(RoadType roadType, double curve, {bool brake = false}) =>
    RoadScene(
      monotonicTimeNanos: 0,
      speedMps: 24,
      setSpeedMps: 27.8,
      steeringAngleDegrees: 0,
      engaged: true,
      brakeActive: brake,
      leftBlinker: true,
      plannedPath: _line(0, curve),
      leftLane: const [],
      rightLane: const [],
      laneLines: [
        LaneLine(points: _line(5.4, curve), color: LaneLineColor.yellow),
        LaneLine(points: _line(1.8, curve)),
        LaneLine(points: _line(-1.8, curve)),
        LaneLine(points: _line(-5.4, curve), style: LaneLineStyle.dashed),
      ],
      roadEdges: [_line(6.3, curve), _line(-9.3, curve)],
      roadType: roadType,
      odometerMeters: 1234,
      objects: [
        TrackedObject(
          distanceMeters: 34.8,
          leftMeters: curve * 34.8 * 34.8,
          relativeSpeedMps: -1,
          isLead: true,
        ),
        TrackedObject(
          distanceMeters: 70,
          leftMeters: -3.6 + curve * 4900,
          relativeSpeedMps: 1,
        ),
        TrackedObject(
          distanceMeters: 95,
          leftMeters: 0.2 + curve * 9025,
          relativeSpeedMps: 1,
        ),
        if (roadType == RoadType.city)
          for (var i = 0; i < 5; i++)
            TrackedObject(
              distanceMeters: 14.0 + i * 9,
              leftMeters: -2.7 + curve * (14.0 + i * 9) * (14.0 + i * 9),
              relativeSpeedMps: 0,
              kind: TrackedObjectKind.trafficCone,
            ),
      ],
    );

void main() {
  testWidgets('capture road world', (tester) async {
    await tester.runAsync(() async {
      await loadReviewFonts();
      for (final (name, size) in const [
        ('landscape', Size(1396, 1099)),
        ('portrait', Size(1080, 1920)),
      ]) {
        await savePainter(
          RoadWorldPainter(
            labelFontFamily: 'Roboto',
            scene: _scene(RoadType.highway, 0.0),
          ),
          size,
          'scene_highway_clear_$name',
        );
        await savePainter(
          RoadWorldPainter(
            labelFontFamily: 'Roboto',
            scene: _scene(RoadType.highway, 0.00035),
          ),
          size,
          'scene_highway_curve_$name',
        );
        await savePainter(
          RoadWorldPainter(
            labelFontFamily: 'Roboto',
            scene: _scene(RoadType.city, -0.0003, brake: true),
            theme: SceneTheme.overcast,
          ),
          size,
          'scene_city_overcast_$name',
        );
        await savePainter(
          RoadWorldPainter(
            labelFontFamily: 'Roboto',
            scene: _scene(RoadType.highway, 0.0002),
            viewpoint: SceneViewpoint.topDown,
          ),
          size,
          'scene_topdown_$name',
        );
        await savePainter(
          RoadWorldPainter(
            labelFontFamily: 'Roboto',
            scene: _scene(RoadType.highway, 0.0002),
            viewpoint: SceneViewpoint.driver,
          ),
          size,
          'scene_driver_$name',
        );
      }
    });
  });
}
