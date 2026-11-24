import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/models/ego_vehicle_profile.dart';
import 'package:kovalink/src/models/road_scene.dart';

/// Which scene elements to draw (설정 → 표시 항목).
class SceneLayers {
  const SceneLayers({
    this.lanes = true,
    this.objects = true,
    this.path = true,
    this.scenery = true,
  });

  final bool lanes;
  final bool objects;
  final bool path;
  final bool scenery;

  @override
  bool operator ==(Object other) =>
      other is SceneLayers &&
      other.lanes == lanes &&
      other.objects == objects &&
      other.path == path &&
      other.scenery == scenery;

  @override
  int get hashCode => Object.hash(lanes, objects, path, scenery);
}

/// 2.5D road-world renderer: a small software 3D pipeline (pinhole camera,
/// near-plane clipping, flat shading, exponential fog, painter's algorithm)
/// drawn with Canvas so it runs identically on every platform and in tests.
///
/// Inputs are only [RoadScene] fields and display settings; it never
/// invents vehicle state. Scene frame: x forward, y left, z up, meters,
/// origin on the ground at the ego front bumper.
class RoadWorldPainter extends CustomPainter {
  const RoadWorldPainter({
    required this.scene,
    this.vehicle = EgoVehicleProfile.builtIn,
    this.viewpoint = SceneViewpoint.chase,
    this.theme = SceneTheme.clear,
    this.layers = const SceneLayers(),
    this.labelFontFamily,
  });

  final RoadScene scene;
  final EgoVehicleProfile vehicle;
  final SceneViewpoint viewpoint;
  final SceneTheme theme;
  final SceneLayers layers;

  /// Font for in-scene labels (distance bubble); null = platform default.
  final String? labelFontFamily;

  static const pathHalfWidth = 0.85;
  static const laneHalfWidth = 0.075;
  static const dashLength = 3.0;
  static const dashPeriod = 9.0;

  /// Default road half-width when the frame has no lanes or edges.
  static const fallbackHalfWidth = 5.4;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final frame = _Frame(
      canvas: canvas,
      size: size,
      camera: SceneCamera.forViewpoint(viewpoint, size, vehicle),
      palette: ScenePalette.resolve(theme, scene.roadType),
    );
    final road = RoadGeometry.fromScene(scene);
    final xs = _samples();

    _paintSkyAndGround(frame);
    _paintRoad(frame, road, xs);
    if (layers.lanes) _paintLanes(frame, xs);
    if (layers.path) _paintPath(frame);
    if (viewpoint != SceneViewpoint.driver && scene.brakeActive) {
      _paintBrakePool(frame);
    }

    final drawables = <_Drawable>[];
    if (layers.scenery) _collectScenery(frame, road, drawables);
    if (layers.objects) _collectObjects(frame, drawables);
    drawables.sort((a, b) => b.depth.compareTo(a.depth));
    for (final drawable in drawables) {
      drawable.paint();
    }

    if (viewpoint == SceneViewpoint.driver) {
      _paintHood(frame);
    } else {
      _paintVehicle(
        frame,
        rear: -vehicle.dimensions.length,
        left: 0,
        length: vehicle.dimensions.length,
        width: vehicle.dimensions.width,
        height: vehicle.dimensions.height,
        paint: Color(vehicle.appearance.paintArgb),
        glass: Color(vehicle.appearance.glassArgb),
        lamp: Color(vehicle.appearance.lampArgb),
        brake: scene.brakeActive,
        ego: true,
      );
    }
    if (layers.objects) _paintLeadBubble(frame);
  }

  List<double> _samples() {
    final (start, end) = switch (viewpoint) {
      SceneViewpoint.chase => (-12.0, 170.0),
      SceneViewpoint.driver => (-1.0, 170.0),
      SceneViewpoint.topDown => (-22.0, 48.0),
    };
    final xs = <double>[];
    for (var x = start; x < end; x += 1.0 + math.max(0, x) * 0.05) {
      xs.add(x);
    }
    xs.add(end);
    return xs;
  }

  // ---------------------------------------------------------------- sky/ground

  void _paintSkyAndGround(_Frame f) {
    final horizon = f.camera.horizonY;
    final rect = Offset.zero & f.size;
    if (horizon == null) {
      f.canvas.drawRect(rect, Paint()..color = f.palette.groundNear);
      return;
    }
    final h = horizon.clamp(0.0, f.size.height);
    f.canvas.drawRect(
      Rect.fromLTRB(0, 0, f.size.width, h + 1),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [f.palette.skyTop, f.palette.skyHorizon, f.palette.fog],
          stops: const [0, 0.82, 1],
        ).createShader(Rect.fromLTRB(0, 0, f.size.width, h + 1)),
    );
    final groundRect = Rect.fromLTRB(0, h, f.size.width, f.size.height);
    if (groundRect.height <= 0) return;
    f.canvas.drawRect(
      groundRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            f.palette.fog,
            f.palette.fogged(f.palette.groundNear, 90),
            f.palette.fogged(f.palette.groundNear, 25),
            f.palette.groundNear,
          ],
          stops: const [0, 0.08, 0.35, 1],
        ).createShader(groundRect),
    );
  }

  // ---------------------------------------------------------------- road

  void _paintRoad(_Frame f, RoadGeometry road, List<double> xs) {
    final p = f.palette;
    // Shoulders, then asphalt, then the red edge bands.
    _strip(
      f,
      xs,
      (x) => road.leftEdge(x) + 2.6,
      road.leftEdge,
      (x) => p.shoulder,
    );
    _strip(
      f,
      xs,
      road.rightEdge,
      (x) => road.rightEdge(x) - 2.6,
      (x) => p.shoulder,
    );
    _strip(
      f,
      xs,
      road.leftEdge,
      road.rightEdge,
      (x) => p.asphaltNear,
      antiAlias: false,
    );
    // Transverse pavement seams every 12 m, scrolling with the odometer.
    final phase = scene.odometerMeters % 12;
    for (var x = -phase - 12; x < xs.last; x += 12) {
      if (x < xs.first) continue;
      _quad(
        f,
        V3(x, road.leftEdge(x), 0.002),
        V3(x, road.rightEdge(x), 0.002),
        V3(x + 0.18, road.rightEdge(x + 0.18), 0.002),
        V3(x + 0.18, road.leftEdge(x + 0.18), 0.002),
        p.asphaltSeam.withValues(alpha: 0.55),
      );
    }
    _strip(
      f,
      xs,
      road.leftEdge,
      (x) => road.leftEdge(x) - 0.32,
      (x) => p.roadEdge,
      z: 0.004,
    );
    _strip(
      f,
      xs,
      (x) => road.rightEdge(x) + 0.32,
      road.rightEdge,
      (x) => p.roadEdge,
      z: 0.004,
    );
  }

  void _paintLanes(_Frame f, List<double> xs) {
    final p = f.palette;
    for (final line in scene.laneLines) {
      if (line.points.length < 2) continue;
      final base = switch (line.color) {
        LaneLineColor.yellow => p.laneYellow,
        LaneLineColor.blue => p.laneBlue,
        _ => p.laneWhite,
      };
      final color = base.withValues(alpha: 0.25 + 0.75 * line.probability);
      double at(double x) => RoadScene.interpolateLeft(line.points, x);
      final lineXs = xs
          .where((x) => x >= math.min(line.points.first.forwardMeters, 0) - 12)
          .where((x) => x <= line.points.last.forwardMeters)
          .toList();
      if (lineXs.length < 2) continue;
      switch (line.style) {
        case LaneLineStyle.dashed:
          final phase = scene.odometerMeters % dashPeriod;
          for (var s = lineXs.first - phase; s < lineXs.last; s += dashPeriod) {
            final a = math.max(s, lineXs.first);
            final b = math.min(s + dashLength, lineXs.last);
            if (b <= a) continue;
            _ribbon(f, [a, (a + b) / 2, b], at, laneHalfWidth, color);
          }
        case LaneLineStyle.doubleSolid:
          _ribbon(f, lineXs, (x) => at(x) + 0.12, laneHalfWidth * 0.8, color);
          _ribbon(f, lineXs, (x) => at(x) - 0.12, laneHalfWidth * 0.8, color);
        case LaneLineStyle.solid || LaneLineStyle.unknown:
          _ribbon(f, lineXs, at, laneHalfWidth, color);
      }
    }
  }

  /// Rainbow planned-path ribbon (청록 → 파랑 → 보라), fading out ahead.
  void _paintPath(_Frame f) {
    final path = scene.plannedPath;
    if (path.length < 2) return;
    final lead = scene.leadObject;
    final end = math.min(
      path.last.forwardMeters,
      lead == null ? double.infinity : lead.distanceMeters - 0.8,
    );
    const start = 0.4;
    if (end <= start + 1) return;
    const stops = [
      Color(0xFF39E6CF),
      Color(0xFF4F9DFF),
      Color(0xFF9B72FF),
      Color(0xFFE071E6),
    ];
    Color colorAt(double t) {
      final scaled = (t.clamp(0.0, 1.0)) * (stops.length - 1);
      final index = scaled.floor().clamp(0, stops.length - 2);
      return Color.lerp(stops[index], stops[index + 1], scaled - index)!;
    }

    final xs = <double>[];
    for (var x = start; x < end; x += 0.6 + x * 0.04) {
      xs.add(x);
    }
    xs.add(end);
    double center(double x) => RoadScene.interpolateLeft(path, x);
    for (var index = 0; index < xs.length - 1; index++) {
      final a = xs[index];
      final b = xs[index + 1];
      final t = ((a + b) / 2 - start) / (end - start);
      final fadeIn = (((a + b) / 2 - start) / 1.5).clamp(0.0, 1.0);
      final alpha = 0.78 * math.pow(1 - t, 0.7) * fadeIn;
      final color = colorAt(t).withValues(alpha: alpha.toDouble());
      _quad(
        f,
        V3(a, center(a) + pathHalfWidth, 0.01),
        V3(a, center(a) - pathHalfWidth, 0.01),
        V3(b, center(b) - pathHalfWidth, 0.01),
        V3(b, center(b) + pathHalfWidth, 0.01),
        color,
        fog: false,
      );
      _quad(
        f,
        V3(a, center(a) + pathHalfWidth * 0.35, 0.012),
        V3(a, center(a) - pathHalfWidth * 0.35, 0.012),
        V3(b, center(b) - pathHalfWidth * 0.35, 0.012),
        V3(b, center(b) + pathHalfWidth * 0.35, 0.012),
        Colors.white.withValues(alpha: alpha * 0.22),
        fog: false,
      );
    }
  }

  void _paintBrakePool(_Frame f) {
    final rear = -vehicle.dimensions.length;
    final halfWidth = vehicle.dimensions.width * 0.75;
    final points = [
      for (var i = 0; i < 16; i++)
        V3(
          rear - 1.4 + math.cos(i / 16 * math.pi * 2) * 1.9,
          math.sin(i / 16 * math.pi * 2) * halfWidth,
          0.02,
        ),
    ];
    final polygon = f.camera.projectPolygon(points);
    if (polygon == null) return;
    final ppm = f.camera.pixelsPerMeter(f.camera.depthOf(V3(rear - 1.4, 0, 0)));
    f.canvas.drawPath(
      Path()..addPolygon(polygon, true),
      Paint()
        ..color = const Color(0x77FF2D45)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          math.max(4, ppm * 0.45),
        ),
    );
  }

  // ---------------------------------------------------------------- scenery

  void _collectScenery(_Frame f, RoadGeometry road, List<_Drawable> out) {
    final odometer = scene.odometerMeters;
    final (start, end) = (
      math.max(_minSampleX, -8.0),
      viewpoint == SceneViewpoint.topDown ? 50.0 : 150.0,
    );
    final trees = f.palette.scenery == SceneryKind.trees;
    final spacing = trees ? 19.0 : 28.0;
    for (final side in const [1, -1]) {
      final first = ((odometer + start) / spacing).floor() - 1;
      final last = ((odometer + end) / spacing).ceil();
      for (var n = first; n <= last; n++) {
        final h = _hash(n * 2 + (side > 0 ? 0 : 1));
        if (trees && h < 0.18) continue;
        final x = n * spacing + _hash(n * 7 + side) * spacing * 0.6 - odometer;
        if (x < start || x > end) continue;
        final edge = side > 0 ? road.leftEdge(x) : road.rightEdge(x);
        if (trees) {
          final offset = 4.0 + _hash(n * 13 + side * 5) * 16;
          final tree = V3(x, edge + side * offset, 0);
          final scale = 0.8 + _hash(n * 17 + side) * 0.7;
          out.add(
            _Drawable(
              f.camera.depthOf(tree),
              () => _paintTree(f, tree, scale, n),
            ),
          );
        } else {
          final offset = 12.0 + _hash(n * 13 + side * 5) * 12;
          final depthX = 10 + _hash(n * 3) * 10;
          final lengthX = 12 + _hash(n * 11 + side) * 12;
          final height = 8 + _hash(n * 19 + side) * 26;
          final near = edge + side * offset;
          final far = near + side * depthX;
          final min = V3(x, math.min(near, far), 0);
          final max = V3(x + lengthX, math.max(near, far), height);
          out.add(
            _Drawable(
              f.camera.depthOf(V3(x + lengthX / 2, (near + far) / 2, 0)),
              () => _box(f, min, max, f.palette.building),
            ),
          );
        }
      }
    }
  }

  // Minimum sampled x for the current viewpoint.
  double get _minSampleX => switch (viewpoint) {
    SceneViewpoint.chase => -12,
    SceneViewpoint.driver => -1,
    SceneViewpoint.topDown => -22,
  };

  void _paintTree(_Frame f, V3 base, double scale, int seed) {
    final trunkHeight = 2.2 * scale;
    final radius = 2.1 * scale;
    // Contact shadow.
    _groundBlob(
      f,
      V3(base.x - 0.6, base.y - 0.8, 0),
      radius * 1.1,
      radius * 0.8,
      f.palette.shadowAlpha * 0.7,
    );
    _box(
      f,
      V3(base.x - 0.16 * scale, base.y - 0.16 * scale, 0),
      V3(
        base.x + 0.16 * scale,
        base.y + 0.16 * scale,
        trunkHeight + radius * 0.4,
      ),
      f.palette.trunk,
    );
    final colors = f.palette.foliage;
    _blob(
      f,
      V3(base.x, base.y, trunkHeight + radius * 0.9),
      radius,
      radius * 1.15,
      colors[seed.abs() % colors.length],
    );
    _blob(
      f,
      V3(
        base.x + 0.3 * scale,
        base.y - 0.25 * scale,
        trunkHeight + radius * 1.75,
      ),
      radius * 0.68,
      radius * 0.8,
      colors[(seed.abs() + 1) % colors.length],
    );
  }

  /// Low-poly foliage: octagonal bipyramid, flat shaded.
  void _blob(
    _Frame f,
    V3 center,
    double radius,
    double halfHeight,
    Color color,
  ) {
    const segments = 8;
    final top = center + V3(0, 0, halfHeight);
    final bottom = center - V3(0, 0, halfHeight * 0.8);
    final ring = [
      for (var i = 0; i < segments; i++)
        center +
            V3(
              math.cos((i + 0.5) / segments * math.pi * 2) * radius,
              math.sin((i + 0.5) / segments * math.pi * 2) * radius,
              (i.isEven ? 0.12 : -0.08) * halfHeight,
            ),
    ];
    for (var i = 0; i < segments; i++) {
      final a = ring[i];
      final b = ring[(i + 1) % segments];
      _face(f, [a, b, top], color);
      _face(f, [b, a, bottom], color);
    }
  }

  // ---------------------------------------------------------------- objects

  void _collectObjects(_Frame f, List<_Drawable> out) {
    final lead = scene.leadObject;
    for (final object in scene.objects) {
      if (object.distanceMeters <= -40 || object.distanceMeters > 180) continue;
      final center = V3(
        object.distanceMeters + object.length / 2,
        object.leftMeters,
        0,
      );
      final depth = f.camera.depthOf(center);
      if (depth < f.camera.nearDepth && viewpoint != SceneViewpoint.topDown) {
        continue;
      }
      out.add(
        _Drawable(depth, () {
          switch (object.kind) {
            case TrackedObjectKind.trafficCone:
              _paintCone(f, V3(object.distanceMeters, object.leftMeters, 0));
            case TrackedObjectKind.pedestrian || TrackedObjectKind.cyclist:
              _groundBlob(
                f,
                center,
                object.length * 0.8,
                object.width * 0.8,
                f.palette.shadowAlpha,
              );
              _box(
                f,
                V3(
                  object.distanceMeters,
                  object.leftMeters - object.width / 2,
                  0,
                ),
                V3(
                  object.distanceMeters + object.length,
                  object.leftMeters + object.width / 2,
                  object.height,
                ),
                const Color(0xFF8FA3B8),
              );
            case TrackedObjectKind.unknown:
              _box(
                f,
                V3(
                  object.distanceMeters,
                  object.leftMeters - object.width / 2,
                  0,
                ),
                V3(
                  object.distanceMeters + object.length,
                  object.leftMeters + object.width / 2,
                  object.height,
                ),
                const Color(0xFFB0B6BC),
              );
            case TrackedObjectKind.vehicle || TrackedObjectKind.truck:
              final isLead = identical(object, lead);
              final body = isLead
                  ? f.palette.leadVehicle
                  : f.palette.otherVehicle;
              _paintVehicle(
                f,
                rear: object.distanceMeters,
                left: object.leftMeters,
                length: object.length,
                width: object.width,
                height: object.height,
                paint: body,
                glass: const Color(0xFF1E2833),
                lamp: const Color(0xFFB3202F),
                brake: object.brakeLights,
                ego: false,
              );
          }
        }),
      );
    }
  }

  void _paintCone(_Frame f, V3 base) {
    _groundBlob(f, base, 0.35, 0.35, f.palette.shadowAlpha * 0.8);
    const segments = 8;
    final apex = base + const V3(0, 0, 0.72);
    final ring = [
      for (var i = 0; i < segments; i++)
        base +
            V3(
              math.cos(i / segments * math.pi * 2) * 0.2,
              math.sin(i / segments * math.pi * 2) * 0.2,
              0.02,
            ),
    ];
    for (var i = 0; i < segments; i++) {
      _face(f, [
        ring[i],
        ring[(i + 1) % segments],
        apex,
      ], const Color(0xFFF07B2C));
    }
    // White reflective band.
    V3 at(int i, double z) {
      final r = 0.2 * (1 - z / 0.72);
      return base +
          V3(
            math.cos(i / segments * math.pi * 2) * r,
            math.sin(i / segments * math.pi * 2) * r,
            z,
          );
    }

    for (var i = 0; i < segments; i++) {
      final j = (i + 1) % segments;
      _face(f, [
        at(i, 0.30),
        at(j, 0.30),
        at(j, 0.44),
        at(i, 0.44),
      ], const Color(0xFFF4F4F2));
    }
  }

  void _paintVehicle(
    _Frame f, {
    required double rear,
    required double left,
    required double length,
    required double width,
    required double height,
    required Color paint,
    required Color glass,
    required Color lamp,
    required bool brake,
    required bool ego,
  }) {
    final front = rear + length;
    final half = width / 2;
    final beltZ = height * 0.58;
    _groundBlob(
      f,
      V3(rear + length / 2, left - 0.15, 0),
      length * 0.62,
      half + 0.35,
      f.palette.shadowAlpha * (ego ? 1.25 : 1),
    );
    // Wheels.
    final overhang = length * 0.2;
    for (final ax in [rear + overhang, front - overhang]) {
      for (final side in const [1, -1]) {
        final y = left + side * (half - 0.16);
        _box(
          f,
          V3(ax - 0.34, y - 0.13, 0),
          V3(ax + 0.34, y + 0.13, 0.66),
          const Color(0xFF1B1D20),
        );
      }
    }
    // Lower body (rounded by a top taper) and cabin: slanted rear window,
    // raked windshield, painted roof.
    _box(
      f,
      V3(rear, left - half, 0.26),
      V3(front, left + half, beltZ),
      paint,
      taper: 0.09,
      taperFront: 0.22,
      gloss: true,
    );
    _box(
      f,
      V3(rear + length * 0.08, left - half + 0.07, beltZ),
      V3(front - length * 0.24, left + half - 0.07, height),
      glass,
      taper: 0.13,
      taperRear: 0.34,
      taperFront: 0.62,
      topColor: paint,
      gloss: true,
    );

    // Rear details only when the rear face points at the camera.
    final rearCenter = V3(rear, left, beltZ * 0.7);
    if (!f.camera.faceVisible(rearCenter, const V3(-1, 0, 0))) return;
    final x = rear - 0.012;
    final lampColor = brake ? const Color(0xFFFF2E48) : lamp;
    // Bumper trim.
    _flat(f, [
      V3(x, left + half - 0.03, 0.27),
      V3(x, left - half + 0.03, 0.27),
      V3(x, left - half + 0.03, 0.36),
      V3(x, left + half - 0.03, 0.36),
    ], Color.lerp(paint, Colors.black, 0.55)!);
    for (final side in const [1, -1]) {
      final outer = left + side * (half - 0.04);
      final inner = left + side * (half - 0.40);
      final glow = brake ? 10.0 : (ego ? 3.0 : 0.0);
      _flat(
        f,
        [
          V3(x, outer, beltZ - 0.13),
          V3(x, inner, beltZ - 0.13),
          V3(x, inner, beltZ - 0.05),
          V3(x, outer, beltZ - 0.05),
        ],
        lampColor,
        glow: glow,
      );
      _flat(
        f,
        [
          V3(x, outer, beltZ - 0.32),
          V3(x, outer - side * 0.09, beltZ - 0.32),
          V3(x, outer - side * 0.09, beltZ - 0.05),
          V3(x, outer, beltZ - 0.05),
        ],
        lampColor,
        glow: glow,
      );
      if (ego && _blinkOn) {
        final on = side > 0 ? scene.leftBlinker : scene.rightBlinker;
        if (on) {
          _flat(
            f,
            [
              V3(x, outer, beltZ - 0.30),
              V3(x, outer - side * 0.18, beltZ - 0.30),
              V3(x, outer - side * 0.18, beltZ - 0.19),
              V3(x, outer, beltZ - 0.19),
            ],
            const Color(0xFFFFB21C),
            glow: 12,
          );
        }
      }
    }
    // Light bar across the tailgate and the plate.
    _flat(
      f,
      [
        V3(x, left + half - 0.40, beltZ - 0.09),
        V3(x, left - half + 0.40, beltZ - 0.09),
        V3(x, left - half + 0.40, beltZ - 0.065),
        V3(x, left + half - 0.40, beltZ - 0.065),
      ],
      lampColor.withValues(alpha: 0.85),
      glow: brake ? 6 : 0,
    );
    _flat(f, [
      V3(x, left + 0.26, 0.38),
      V3(x, left - 0.26, 0.38),
      V3(x, left - 0.26, 0.49),
      V3(x, left + 0.26, 0.49),
    ], const Color(0xFFF1F3F5));
    if (brake) {
      // High-mount stop lamp at the top of the slanted rear window.
      final cabinRear = rear + length * 0.08 + 0.30;
      _flat(
        f,
        [
          V3(cabinRear, left + 0.28, height - 0.10),
          V3(cabinRear, left - 0.28, height - 0.10),
          V3(cabinRear, left - 0.28, height - 0.06),
          V3(cabinRear, left + 0.28, height - 0.06),
        ],
        const Color(0xFFFF2E48),
        glow: 8,
      );
    }
  }

  bool get _blinkOn => (scene.monotonicTimeNanos ~/ 500000000).isEven;

  void _paintHood(_Frame f) {
    final eyeX = -vehicle.dimensions.length * 0.42;
    final half = vehicle.dimensions.width / 2;
    final beltZ = vehicle.dimensions.height * 0.55;
    _box(
      f,
      V3(eyeX + 1.2, -half, 0.3),
      V3(0, half, beltZ),
      Color(vehicle.appearance.paintArgb),
      taper: 0.08,
      gloss: true,
    );
  }

  void _paintLeadBubble(_Frame f) {
    final lead = scene.leadObject;
    if (lead == null || lead.distanceMeters <= 0) return;
    final anchor = f.camera.project(
      V3(
        lead.distanceMeters + lead.length * 0.4,
        lead.leftMeters,
        lead.height + 0.9,
      ),
    );
    if (anchor == null) return;
    final text = TextPainter(
      text: TextSpan(
        text: '${lead.distanceMeters.toStringAsFixed(1)} m',
        style: TextStyle(
          fontFamily: labelFontFamily,
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromCenter(
      center: anchor.offset.translate(0, -text.height / 2 - 8),
      width: text.width + 22,
      height: text.height + 10,
    );
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(rect.height / 2),
    );
    f.canvas.drawRRect(
      rrect.shift(const Offset(0, 3)),
      Paint()
        ..color = const Color(0x40000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    f.canvas.drawRRect(
      rrect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF4A86FF), Color(0xFF2458E0)],
        ).createShader(rect),
    );
    f.canvas.drawRRect(
      rrect,
      Paint()
        ..color = const Color(0x66FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    f.canvas.drawPath(
      Path()
        ..moveTo(rect.center.dx - 5, rect.bottom - 0.5)
        ..lineTo(rect.center.dx + 5, rect.bottom - 0.5)
        ..lineTo(rect.center.dx, rect.bottom + 6)
        ..close(),
      Paint()..color = const Color(0xFF2458E0),
    );
    text.paint(f.canvas, rect.center - Offset(text.width / 2, text.height / 2));
  }

  // ---------------------------------------------------------------- primitives

  void _strip(
    _Frame f,
    List<double> xs,
    double Function(double x) a,
    double Function(double x) b,
    Color Function(double x) color, {
    double z = 0,
    bool antiAlias = true,
  }) {
    for (var index = 0; index < xs.length - 1; index++) {
      final x0 = xs[index];
      // Slight overlap hides seams between neighbouring quads.
      final x1 = xs[index + 1] + 0.05;
      _quad(
        f,
        V3(x0, a(x0), z),
        V3(x0, b(x0), z),
        V3(x1, b(x1), z),
        V3(x1, a(x1), z),
        color((x0 + x1) / 2),
        antiAlias: antiAlias,
      );
    }
  }

  void _ribbon(
    _Frame f,
    List<double> xs,
    double Function(double x) center,
    double halfWidth,
    Color color,
  ) {
    _strip(
      f,
      xs,
      (x) => center(x) + halfWidth,
      (x) => center(x) - halfWidth,
      (x) => color,
      z: 0.006,
    );
  }

  void _quad(
    _Frame f,
    V3 a,
    V3 b,
    V3 c,
    V3 d,
    Color color, {
    bool fog = true,
    bool antiAlias = true,
  }) {
    final polygon = f.camera.projectPolygon([a, b, c, d]);
    if (polygon == null) return;
    final mid = V3.lerp(V3.lerp(a, b, 0.5), V3.lerp(c, d, 0.5), 0.5);
    final shaded = fog ? f.palette.fogged(color, f.camera.depthOf(mid)) : color;
    f.canvas.drawPath(
      Path()..addPolygon(polygon, true),
      Paint()
        ..color = shaded
        ..isAntiAlias = antiAlias,
    );
  }

  /// Draws a planar polygon facing the camera without shading.
  void _flat(_Frame f, List<V3> points, Color color, {double glow = 0}) {
    final polygon = f.camera.projectPolygon(points);
    if (polygon == null) return;
    final path = Path()..addPolygon(polygon, true);
    if (glow > 0) {
      f.canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.75)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, glow),
      );
    }
    f.canvas.drawPath(path, Paint()..color = color);
  }

  /// Flat-shaded polygon with back-face culling. Points wind
  /// counter-clockwise when seen from outside.
  void _face(_Frame f, List<V3> points, Color color, {bool gloss = false}) {
    final normal = _normal(points[0], points[1], points[2]);
    var center = const V3(0, 0, 0);
    for (final point in points) {
      center = center + point;
    }
    center = center.scale(1 / points.length);
    if (!f.camera.faceVisible(center, normal)) return;
    final polygon = f.camera.projectPolygon(points);
    if (polygon == null) return;
    final light = f.palette.lightDirection;
    final diffuse = math.max(
      0.0,
      normal.x * light.$1 + normal.y * light.$2 + normal.z * light.$3,
    );
    final lit = Color.lerp(Colors.black, color, 0.58 + 0.42 * diffuse)!;
    final shaded = f.palette.fogged(lit, f.camera.depthOf(center));
    final path = Path()..addPolygon(polygon, true);
    f.canvas.drawPath(path, Paint()..color = shaded);
    if (gloss) {
      final bounds = path.getBounds();
      if (bounds.isEmpty) return;
      // Sky reflection: a soft diagonal highlight across the panel.
      f.canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: normal.z > 0.5 ? 0.30 : 0.22),
              Colors.white.withValues(alpha: 0.04),
              Colors.white.withValues(alpha: 0.0),
              Colors.white.withValues(alpha: 0.10),
            ],
            stops: const [0, 0.38, 0.7, 1],
          ).createShader(bounds),
      );
    }
  }

  /// Axis-aligned box (optionally tapered at the top). Bottom face omitted.
  void _box(
    _Frame f,
    V3 min,
    V3 max,
    Color color, {
    double taper = 0,
    double? taperRear,
    double? taperFront,
    Color? topColor,
    bool gloss = false,
  }) {
    final span = (max.x - min.x) / 2.2;
    final tr = math.min(taperRear ?? taper, span);
    final tf = math.min(taperFront ?? taper, span);
    final ty = math.min(taper, (max.y - min.y) / 3);
    final b0 = V3(min.x, min.y, min.z);
    final b1 = V3(max.x, min.y, min.z);
    final b2 = V3(max.x, max.y, min.z);
    final b3 = V3(min.x, max.y, min.z);
    final t0 = V3(min.x + tr, min.y + ty, max.z);
    final t1 = V3(max.x - tf, min.y + ty, max.z);
    final t2 = V3(max.x - tf, max.y - ty, max.z);
    final t3 = V3(min.x + tr, max.y - ty, max.z);
    _face(f, [b0, t0, t3, b3], color, gloss: gloss); // rear (-x)
    _face(f, [b0, b1, t1, t0], color, gloss: gloss); // right (-y)
    _face(f, [b3, t3, t2, b2], color, gloss: gloss); // left (+y)
    _face(f, [b1, b2, t2, t1], color, gloss: gloss); // front (+x)
    _face(f, [t0, t1, t2, t3], topColor ?? color, gloss: gloss); // top
  }

  void _groundBlob(
    _Frame f,
    V3 center,
    double halfLength,
    double halfWidth,
    double alpha,
  ) {
    final points = [
      for (var i = 0; i < 14; i++)
        V3(
          center.x + math.cos(i / 14 * math.pi * 2) * halfLength,
          center.y + math.sin(i / 14 * math.pi * 2) * halfWidth,
          0.015,
        ),
    ];
    final polygon = f.camera.projectPolygon(points);
    if (polygon == null) return;
    final ppm = f.camera.pixelsPerMeter(f.camera.depthOf(center));
    f.canvas.drawPath(
      Path()..addPolygon(polygon, true),
      Paint()
        ..color = Colors.black.withValues(alpha: alpha)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          math.max(1.5, ppm * 0.28),
        ),
    );
  }

  static V3 _normal(V3 a, V3 b, V3 c) {
    final u = b - a;
    final v = c - a;
    final n = V3(
      u.y * v.z - u.z * v.y,
      u.z * v.x - u.x * v.z,
      u.x * v.y - u.y * v.x,
    );
    final length = math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    return length == 0 ? const V3(0, 0, 1) : n.scale(1 / length);
  }

  static double _hash(int n) {
    var h = (n * 0x27d4eb2d) & 0x7fffffff;
    h = (h ^ (h >> 15)) * 0x2c1b3c6d & 0x7fffffff;
    h = (h ^ (h >> 12)) * 0x297a2d39 & 0x7fffffff;
    h ^= h >> 15;
    return (h & 0xffff) / 0x10000;
  }

  @override
  bool shouldRepaint(covariant RoadWorldPainter oldDelegate) =>
      oldDelegate.scene != scene ||
      oldDelegate.vehicle != vehicle ||
      oldDelegate.viewpoint != viewpoint ||
      oldDelegate.theme != theme ||
      oldDelegate.layers != layers ||
      oldDelegate.labelFontFamily != labelFontFamily;
}

/// Road boundaries as functions of forward distance.
class RoadGeometry {
  const RoadGeometry({required this.leftEdge, required this.rightEdge});

  final double Function(double x) leftEdge;
  final double Function(double x) rightEdge;

  /// Priority: reported road edges → outermost lane lines + 0.6 m →
  /// planned path ± [RoadWorldPainter.fallbackHalfWidth].
  factory RoadGeometry.fromScene(RoadScene scene) {
    final edges = scene.roadEdges.where((edge) => edge.length >= 2).toList();
    if (edges.length >= 2) {
      double mean(List<ScenePoint> e) =>
          e.map((p) => p.leftMeters).reduce((a, b) => a + b) / e.length;
      edges.sort((a, b) => mean(b).compareTo(mean(a)));
      final left = edges.first;
      final right = edges.last;
      return RoadGeometry(
        leftEdge: (x) => RoadScene.interpolateLeft(left, x),
        rightEdge: (x) => RoadScene.interpolateLeft(right, x),
      );
    }
    final lines = scene.laneLines
        .where((line) => line.points.length >= 2)
        .toList();
    if (lines.length >= 2) {
      double mean(LaneLine l) =>
          l.points.map((p) => p.leftMeters).reduce((a, b) => a + b) /
          l.points.length;
      lines.sort((a, b) => mean(b).compareTo(mean(a)));
      final left = lines.first.points;
      final right = lines.last.points;
      return RoadGeometry(
        leftEdge: (x) => RoadScene.interpolateLeft(left, x) + 0.6,
        rightEdge: (x) => RoadScene.interpolateLeft(right, x) - 0.6,
      );
    }
    return RoadGeometry(
      leftEdge: (x) => scene.pathLeftAt(x) + RoadWorldPainter.fallbackHalfWidth,
      rightEdge: (x) =>
          scene.pathLeftAt(x) - RoadWorldPainter.fallbackHalfWidth,
    );
  }
}

class _Frame {
  const _Frame({
    required this.canvas,
    required this.size,
    required this.camera,
    required this.palette,
  });

  final Canvas canvas;
  final Size size;
  final SceneCamera camera;
  final ScenePalette palette;
}

class _Drawable {
  const _Drawable(this.depth, this.paint);

  final double depth;
  final VoidCallback paint;
}
