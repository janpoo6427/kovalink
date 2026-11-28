import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/models/ego_vehicle_profile.dart';
import 'package:kovalink/src/models/road_scene.dart';

List<ScenePoint> _line(double left, {double curve = 0, double length = 120}) =>
    [
      for (var x = 0.0; x <= length; x += 10)
        ScenePoint(forwardMeters: x, leftMeters: left + curve * x * x),
    ];

RoadScene _scene({
  List<TrackedObject> objects = const [],
  bool brake = false,
  RoadType roadType = RoadType.highway,
  double curve = 0,
}) => RoadScene(
  monotonicTimeNanos: 0,
  speedMps: 25,
  setSpeedMps: 27,
  steeringAngleDegrees: 0,
  engaged: true,
  brakeActive: brake,
  plannedPath: _line(0, curve: curve),
  leftLane: const [],
  rightLane: const [],
  laneLines: [
    LaneLine(
      points: _line(5.4, curve: curve),
      color: LaneLineColor.yellow,
    ),
    LaneLine(
      points: _line(1.8, curve: curve),
      style: LaneLineStyle.dashed,
    ),
    LaneLine(
      points: _line(-1.8, curve: curve),
      style: LaneLineStyle.dashed,
    ),
    LaneLine(points: _line(-5.4, curve: curve)),
  ],
  roadEdges: [
    _line(6.2, curve: curve),
    _line(-6.2, curve: curve),
  ],
  roadType: roadType,
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

  group('road scene model', () {
    test('legacy leftLane/rightLane frames become solid white lane lines', () {
      final scene = RoadScene.fromJson({
        'monotonicTimeNanos': 1,
        'speedMps': 10,
        'leftLane': [
          {'x': 0, 'y': 1.8},
          {'x': 50, 'y': 1.9},
        ],
        'rightLane': [
          {'x': 0, 'y': -1.8},
          {'x': 50, 'y': -1.7},
        ],
      });
      expect(scene.laneLines, hasLength(2));
      expect(scene.laneLines.first.color, LaneLineColor.white);
      expect(scene.laneLines.first.style, LaneLineStyle.solid);
      expect(scene.laneLines.first.probability, 1);
      expect(scene.roadType, RoadType.unknown);
    });

    test('parses typed lane lines, edges, road type and object sizes', () {
      final scene = RoadScene.fromJson({
        'monotonicTimeNanos': 1,
        'speedMps': 10,
        'roadType': 'city',
        'odometerMeters': 1234.5,
        'laneLines': [
          {
            'points': [
              {'x': 0, 'y': 1.8},
              {'x': 40, 'y': 1.8},
            ],
            'probability': 1.7,
            'color': 'yellow',
            'style': 'doubleSolid',
          },
          {'points': <Object>[], 'color': 'magenta', 'style': 'zigzag'},
        ],
        'roadEdges': [
          [
            {'x': 0, 'y': 6},
            {'x': 40, 'y': 6},
          ],
        ],
        'objects': [
          {
            'distanceMeters': 30,
            'leftMeters': 0,
            'kind': 'truck',
            'isLead': true,
            'brakeLights': true,
            'id': 7,
          },
          {
            'distanceMeters': 12,
            'leftMeters': 3,
            'kind': 'trafficCone',
            'lengthMeters': -1,
          },
          {'distanceMeters': 50, 'leftMeters': 0, 'kind': 'hovercraft'},
        ],
      });
      expect(scene.roadType, RoadType.city);
      expect(scene.odometerMeters, 1234.5);
      expect(scene.laneLines.first.probability, 1);
      expect(scene.laneLines.first.color, LaneLineColor.yellow);
      expect(scene.laneLines.first.style, LaneLineStyle.doubleSolid);
      expect(scene.laneLines.last.color, LaneLineColor.unknown);
      expect(scene.laneLines.last.style, LaneLineStyle.unknown);
      expect(scene.roadEdges.single, hasLength(2));
      final truck = scene.objects.first;
      expect(truck.kind, TrackedObjectKind.truck);
      expect(truck.length, 9.0);
      expect(truck.isLead && truck.brakeLights, isTrue);
      expect(truck.id, 7);
      expect(scene.objects[1].length, 0.4, reason: 'non-positive size ignored');
      expect(scene.objects[2].kind, TrackedObjectKind.unknown);
      expect(scene.leadObject, same(truck));
    });

    test('lead falls back to the nearest vehicle in the path corridor', () {
      final scene = _scene(
        objects: const [
          TrackedObject(
            distanceMeters: 20,
            leftMeters: 3.6,
            relativeSpeedMps: 0,
          ),
          TrackedObject(
            distanceMeters: 45,
            leftMeters: 0.3,
            relativeSpeedMps: 0,
          ),
          TrackedObject(
            distanceMeters: 30,
            leftMeters: 0.2,
            relativeSpeedMps: 0,
            kind: TrackedObjectKind.trafficCone,
          ),
          TrackedObject(
            distanceMeters: 70,
            leftMeters: -0.2,
            relativeSpeedMps: 0,
          ),
        ],
      );
      expect(scene.leadObject?.distanceMeters, 45);
      expect(_scene().leadObject, isNull);
    });

    test('lane interpolation extrapolates behind and beyond samples', () {
      final points = [
        const ScenePoint(forwardMeters: 0, leftMeters: 1),
        const ScenePoint(forwardMeters: 10, leftMeters: 2),
      ];
      expect(RoadScene.interpolateLeft(points, 5), closeTo(1.5, 1e-9));
      expect(RoadScene.interpolateLeft(points, -10), closeTo(0, 1e-9));
      expect(RoadScene.interpolateLeft(points, 20), closeTo(3, 1e-9));
    });
  });

  group('scene camera', () {
    for (final size in const [
      Size(1080, 1920),
      Size(1396, 1099),
      Size(1081, 1200),
    ]) {
      test('chase camera places horizon and ego contact for $size', () {
        final camera = PerspectiveCamera.chase(size);
        final horizon = camera.horizonY / size.height;
        expect(horizon, inInclusiveRange(0.41, 0.47));
        final contact = camera.project(const V3(-4.5, 0, 0))!.offset;
        expect(contact.dy / size.height, inInclusiveRange(0.79, 0.86));
        expect(contact.dx, closeTo(size.width / 2, 1e-6));
        final left = camera.project(const V3(-4.5, 0.93, 0))!.offset;
        final right = camera.project(const V3(-4.5, -0.93, 0))!.offset;
        final egoFraction = (right.dx - left.dx) / size.width;
        // Wider chase intentionally scales the previous projected size to 70%.
        expect(
          egoFraction,
          inInclusiveRange(
            0.15 * PerspectiveCamera.chaseFramingScale,
            0.25 * PerspectiveCamera.chaseFramingScale,
          ),
        );
        expect(left.dx, lessThan(right.dx), reason: '+y is left on screen');
      });
    }

    test(
      'farther ground points rise toward the horizon; behind is clipped',
      () {
        final camera = PerspectiveCamera.chase(const Size(1080, 1920));
        final near = camera.project(const V3(5, 0, 0))!;
        final far = camera.project(const V3(80, 0, 0))!;
        expect(far.offset.dy, lessThan(near.offset.dy));
        expect(far.offset.dy, greaterThan(camera.horizonY));
        expect(far.depth, greaterThan(near.depth));
        expect(camera.project(const V3(-30, 0, 0)), isNull);
        final polygon = camera.projectPolygon(const [
          V3(-30, 1, 0),
          V3(-30, -1, 0),
          V3(10, -1, 0),
          V3(10, 1, 0),
        ]);
        expect(polygon, isNotNull);
        expect(polygon!.length, greaterThanOrEqualTo(3));
      },
    );

    test('back-face test hides faces pointing away from the camera', () {
      final camera = PerspectiveCamera.chase(const Size(800, 600));
      expect(
        camera.faceVisible(const V3(-4.5, 0, 0.5), const V3(-1, 0, 0)),
        isTrue,
      );
      expect(
        camera.faceVisible(const V3(0, 0, 0.5), const V3(1, 0, 0)),
        isFalse,
      );
      final top = TopDownCamera(const Size(800, 600));
      expect(top.faceVisible(const V3(0, 0, 1), const V3(0, 0, 1)), isTrue);
      expect(top.faceVisible(const V3(0, 0, 1), const V3(-1, 0, 0)), isFalse);
      expect(top.horizonY, isNull);
    });

    test('top-down keeps metric scale and forward is up', () {
      final camera = TopDownCamera(const Size(700, 1400));
      final a = camera.project(const V3(0, 0, 0))!.offset;
      final b = camera.project(const V3(10, 0, 0))!.offset;
      final c = camera.project(const V3(0, 2, 0))!.offset;
      expect(a.dy - b.dy, closeTo(10 * camera.scale, 1e-9));
      expect(a.dx - c.dx, closeTo(2 * camera.scale, 1e-9));
    });

    test('driver eye sits inside the cabin near the left seat', () {
      final camera = PerspectiveCamera.driver(
        const Size(800, 600),
        EgoVehicleProfile.builtIn,
      );
      expect(camera.eye.x, closeTo(-4.5 * 0.42, 1e-9));
      expect(camera.eye.y, greaterThan(0));
      expect(camera.horizonY, lessThan(300));
    });
  });

  group('road world painter', () {
    test(
      'paints every viewpoint, theme and road type without errors',
      () async {
        for (final viewpoint in SceneViewpoint.values) {
          for (final theme in SceneTheme.values) {
            for (final roadType in RoadType.values) {
              final image = await _render(
                RoadWorldPainter(
                  scene: _scene(
                    roadType: roadType,
                    curve: 0.0004,
                    brake: true,
                    objects: const [
                      TrackedObject(
                        distanceMeters: 30,
                        leftMeters: 0,
                        relativeSpeedMps: -2,
                        isLead: true,
                      ),
                      TrackedObject(
                        distanceMeters: 60,
                        leftMeters: -3.6,
                        relativeSpeedMps: 1,
                      ),
                      TrackedObject(
                        distanceMeters: 15,
                        leftMeters: 4.5,
                        relativeSpeedMps: 0,
                        kind: TrackedObjectKind.trafficCone,
                      ),
                      TrackedObject(
                        distanceMeters: 25,
                        leftMeters: 7,
                        relativeSpeedMps: 0,
                        kind: TrackedObjectKind.pedestrian,
                      ),
                    ],
                  ),
                  viewpoint: viewpoint,
                  theme: theme,
                ),
                const Size(360, 640),
              );
              expect(image.width, 360);
            }
          }
        }
      },
    );

    test('empty legacy frame still draws sky, road and ego', () async {
      const empty = RoadScene(
        monotonicTimeNanos: 0,
        speedMps: 0,
        setSpeedMps: 0,
        steeringAngleDegrees: 0,
        engaged: false,
        plannedPath: [],
        leftLane: [],
        rightLane: [],
        objects: [],
      );
      const size = Size(400, 700);
      final image = await _render(const RoadWorldPainter(scene: empty), size);
      final camera = PerspectiveCamera.chase(size);
      final sky = await _pixel(image, const Offset(200, 10));
      expect(
        _c(sky.b),
        greaterThan(_c(sky.r)),
        reason: 'clear sky is blue-ish',
      );
      // Ego rear face just above the contact point is the default paint.
      final rear = camera.project(const V3(-4.5, 0.6, 0.55))!.offset;
      final pixel = await _pixel(image, rear);
      expect(_c(pixel.r), lessThan(140));
    });

    test(
      'lead vehicle is blue with a distance bubble, others are light',
      () async {
        const size = Size(600, 800);
        final scene = _scene(
          objects: const [
            TrackedObject(
              distanceMeters: 22,
              leftMeters: 0,
              relativeSpeedMps: -1,
              isLead: true,
            ),
            TrackedObject(
              distanceMeters: 26,
              leftMeters: -3.6,
              relativeSpeedMps: 1,
            ),
          ],
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
        expect(
          _c(lead.b) - _c(lead.r),
          greaterThan(40),
          reason: 'lead is blue',
        );
        final other = await _pixel(
          image,
          camera.project(const V3(26, -3.6, 0.55))!.offset,
        );
        expect(
          _c(other.r),
          greaterThan(150),
          reason: 'other vehicles are white/light',
        );
        expect((_c(other.b) - _c(other.r)).abs(), lessThan(40));
        final bubble = await _pixel(
          image,
          camera
              .project(const V3(22 + 4.6 * 0.4, 0, 1.45 + 0.9))!
              .offset
              .translate(0, -16),
        );
        expect(_c(bubble.b), greaterThan(180), reason: 'blue distance bubble');
      },
    );

    test(
      'rainbow path starts cyan in front of the ego and stops at the lead',
      () async {
        const size = Size(600, 800);
        final image = await _render(
          RoadWorldPainter(
            scene: _scene(
              objects: const [
                TrackedObject(
                  distanceMeters: 40,
                  leftMeters: 0,
                  relativeSpeedMps: 0,
                  isLead: true,
                ),
              ],
            ),
            layers: const SceneLayers(scenery: false),
          ),
          size,
        );
        final camera = PerspectiveCamera.chase(size);
        final near = await _pixel(
          image,
          camera.project(const V3(6, 0.4, 0))!.offset,
        );
        expect(
          _c(near.g),
          greaterThan(_c(near.r) + 30),
          reason: 'cyan-green start',
        );
        final hidden = await _render(
          RoadWorldPainter(
            scene: _scene(),
            layers: const SceneLayers(path: false, scenery: false),
          ),
          size,
        );
        final asphalt = await _pixel(
          hidden,
          camera.project(const V3(6, 0.4, 0))!.offset,
        );
        expect(_c(asphalt.g), lessThan(_c(near.g)));
      },
    );

    test('brake paints red tail lamps and a red pool on the road', () async {
      const size = Size(600, 800);
      final camera = PerspectiveCamera.chase(size);
      final at = camera.project(const V3(-4.5 - 1.6, 0, 0))!.offset;
      Future<Color> sample(bool brake) async => _pixel(
        await _render(RoadWorldPainter(scene: _scene(brake: brake)), size),
        at,
      );
      final off = await sample(false);
      final on = await sample(true);
      expect(_c(on.r) - _c(off.r), greaterThan(25));
      expect(_c(on.r), greaterThan(_c(on.b)));
    });

    test(
      'overcast city theme is lighter and greyer than clear highway',
      () async {
        const size = Size(400, 700);
        final clear = await _render(RoadWorldPainter(scene: _scene()), size);
        final city = await _render(
          RoadWorldPainter(
            scene: _scene(roadType: RoadType.city),
            theme: SceneTheme.overcast,
          ),
          size,
        );
        final clearSky = await _pixel(clear, const Offset(200, 20));
        final citySky = await _pixel(city, const Offset(200, 20));
        double saturation(Color c) =>
            (math.max(c.r, math.max(c.g, c.b)) -
            math.min(c.r, math.min(c.g, c.b)));
        expect(saturation(citySky), lessThan(saturation(clearSky)));
        expect(_c(citySky.r), greaterThan(_c(clearSky.r)));
      },
    );

    test('layers hide lanes and objects', () async {
      const size = Size(600, 800);
      final camera = PerspectiveCamera.chase(size);
      final scene = _scene(
        objects: const [
          TrackedObject(
            distanceMeters: 22,
            leftMeters: 0,
            relativeSpeedMps: 0,
            isLead: true,
          ),
        ],
      );
      final hidden = await _render(
        RoadWorldPainter(
          scene: scene,
          layers: const SceneLayers(
            objects: false,
            path: false,
            scenery: false,
          ),
        ),
        size,
      );
      final lead = await _pixel(
        hidden,
        camera.project(const V3(22, 0, 0.55))!.offset,
      );
      expect(_c(lead.b) - _c(lead.r), lessThan(25));
      final yellow = camera.project(const V3(8, 5.4, 0))!.offset;
      const noScenery = SceneLayers(scenery: false);
      final withLanes = await _pixel(
        await _render(RoadWorldPainter(scene: scene, layers: noScenery), size),
        yellow,
      );
      final noLanes = await _pixel(
        await _render(
          RoadWorldPainter(
            scene: scene,
            layers: const SceneLayers(lanes: false, scenery: false),
          ),
          size,
        ),
        yellow,
      );
      expect(
        _c(withLanes.r) - _c(withLanes.b),
        greaterThan(60),
        reason: 'yellow center line',
      );
      expect(_c(noLanes.r) - _c(noLanes.b), lessThan(30));
    });

    test('repaints when display settings change', () {
      final scene = _scene();
      final painter = RoadWorldPainter(scene: scene);
      expect(painter.shouldRepaint(RoadWorldPainter(scene: scene)), isFalse);
      expect(
        painter.shouldRepaint(
          RoadWorldPainter(scene: scene, viewpoint: SceneViewpoint.topDown),
        ),
        isTrue,
      );
      expect(
        painter.shouldRepaint(
          RoadWorldPainter(scene: scene, theme: SceneTheme.overcast),
        ),
        isTrue,
      );
      expect(
        painter.shouldRepaint(
          RoadWorldPainter(
            scene: scene,
            layers: const SceneLayers(lanes: false),
          ),
        ),
        isTrue,
      );
    });
  });
}
