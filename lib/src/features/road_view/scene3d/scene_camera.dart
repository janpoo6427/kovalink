import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:kovalink/src/models/ego_vehicle_profile.dart';

/// Camera position choices for the road view (설정 → 시점).
enum SceneViewpoint {
  /// Third-person, behind and above the ego vehicle (default).
  chase,

  /// Bird's-eye, orthographic, north-up = vehicle-forward.
  topDown,

  /// Near the driver's eye point; only the hood of the ego is visible.
  driver,
}

/// A point in the road-scene frame: `x` forward, `y` left, `z` up, meters.
/// Origin: ground level at the ego front bumper center.
class V3 {
  const V3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  V3 operator +(V3 other) => V3(x + other.x, y + other.y, z + other.z);
  V3 operator -(V3 other) => V3(x - other.x, y - other.y, z - other.z);
  V3 scale(double factor) => V3(x * factor, y * factor, z * factor);

  static V3 lerp(V3 a, V3 b, double t) =>
      V3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t);
}

class ProjectedPoint {
  const ProjectedPoint(this.offset, this.depth);

  final Offset offset;

  /// Distance along the camera's viewing axis, meters (used for fog and
  /// painter's-algorithm ordering).
  final double depth;
}

/// Projects scene-frame points to screen pixels for one viewpoint.
abstract class SceneCamera {
  const SceneCamera();

  factory SceneCamera.forViewpoint(
    SceneViewpoint viewpoint,
    Size size,
    EgoVehicleProfile vehicle,
  ) => switch (viewpoint) {
    SceneViewpoint.chase => PerspectiveCamera.chase(size),
    SceneViewpoint.driver => PerspectiveCamera.driver(size, vehicle),
    SceneViewpoint.topDown => TopDownCamera(size),
  };

  double get nearDepth;

  /// Camera-axis depth of a scene point (may be negative = behind).
  double depthOf(V3 point);

  /// Screen position, or null when the point is behind the near plane.
  ProjectedPoint? project(V3 point);

  /// Screen y of the horizon, or null when there is none (top-down).
  double? get horizonY;

  /// Screen pixels per meter at [depth] (lateral scale).
  double pixelsPerMeter(double depth);

  /// Back-face test for a face with outward [normal] at [center].
  bool faceVisible(V3 center, V3 normal);

  /// Eye position for view vectors, or null for orthographic views (the
  /// view direction is then straight down).
  V3? get eyePoint;

  /// Batch projection for meshes: [xyz] holds points, [screen] receives
  /// x/y pixels and [depth] the camera-axis depth (points with depth below
  /// [nearDepth] get undefined screen values).
  void projectAll(Float64List xyz, Float32List screen, Float64List depth);

  /// Clips a planar polygon against the near plane and projects it.
  /// Returns null when nothing is in front of the camera.
  List<Offset>? projectPolygon(List<V3> points) {
    final near = nearDepth;
    final clipped = <V3>[];
    for (var index = 0; index < points.length; index++) {
      final a = points[index];
      final b = points[(index + 1) % points.length];
      final da = depthOf(a) - near;
      final db = depthOf(b) - near;
      if (da >= 0) clipped.add(a);
      if ((da >= 0) != (db >= 0)) {
        clipped.add(V3.lerp(a, b, da / (da - db)));
      }
    }
    if (clipped.length < 3) return null;
    final out = <Offset>[];
    for (final point in clipped) {
      final projected = project(point);
      if (projected == null) return null;
      out.add(projected.offset);
    }
    return out;
  }
}

/// Pinhole camera with pitch only (no roll/yaw), looking along +x.
class PerspectiveCamera extends SceneCamera {
  const PerspectiveCamera({
    required this.eye,
    required this.pitchRadians,
    required this.focalPixels,
    required this.center,
    this.nearDepth = 0.5,
  });

  /// Third-person camera solved from screen-space targets so the ego keeps
  /// a similar on-screen size and the horizon a similar height on phones
  /// (portrait) and tablets/landscape mounts.
  factory PerspectiveCamera.chase(Size size) {
    final aspect = (size.width / size.height).clamp(0.45, 1.8);
    final t = ((aspect - 0.5) / 1.0).clamp(0.0, 1.0);
    final egoWidthFraction = _lerp(0.24, 0.17, t);
    final horizonFraction = _lerp(0.42, 0.46, t);
    final contactFraction = _lerp(0.80, 0.85, t);
    final focal = egoWidthFraction * size.width * chaseDistance / 1.86;
    final centerY = size.height * 0.5;
    final tanPitch = (centerY - horizonFraction * size.height) / focal;
    final g = (contactFraction * size.height - centerY) / focal;
    final height = chaseDistance * (g + tanPitch) / (1 - g * tanPitch);
    return PerspectiveCamera(
      // Behind the rear bumper of a reference-length (4.5 m) car.
      eye: V3(-4.5 - chaseDistance, 0, height),
      pitchRadians: math.atan(tanPitch),
      focalPixels: focal,
      center: Offset(size.width / 2, centerY),
    );
  }

  /// Driver eye point: about 42 % of the body length behind the front
  /// bumper, 0.37 m left of center, 1.3 m above ground.
  factory PerspectiveCamera.driver(Size size, EgoVehicleProfile vehicle) {
    final focal = size.width * 0.78;
    return PerspectiveCamera(
      eye: V3(-vehicle.dimensions.length * 0.42, 0.37, 1.3),
      pitchRadians: 0.02,
      focalPixels: focal,
      center: Offset(size.width / 2, size.height * 0.5),
      nearDepth: 0.3,
    );
  }

  static const chaseDistance = 9.0;

  final V3 eye;
  final double pitchRadians;
  final double focalPixels;
  final Offset center;
  @override
  final double nearDepth;

  double get _sin => math.sin(pitchRadians);
  double get _cos => math.cos(pitchRadians);

  @override
  double depthOf(V3 point) {
    final d = point - eye;
    return d.x * _cos - d.z * _sin;
  }

  @override
  ProjectedPoint? project(V3 point) {
    final d = point - eye;
    final depth = d.x * _cos - d.z * _sin;
    if (depth < nearDepth - 1e-9) return null;
    final up = d.x * _sin + d.z * _cos;
    return ProjectedPoint(
      Offset(
        center.dx - focalPixels * d.y / depth,
        center.dy - focalPixels * up / depth,
      ),
      depth,
    );
  }

  @override
  double get horizonY => center.dy - focalPixels * math.tan(pitchRadians);

  @override
  double pixelsPerMeter(double depth) =>
      focalPixels / math.max(depth, nearDepth);

  @override
  bool faceVisible(V3 center, V3 normal) {
    final view = center - eye;
    return view.x * normal.x + view.y * normal.y + view.z * normal.z < 0;
  }

  @override
  V3? get eyePoint => eye;

  /// Horizontal field of view, radians, for a screen [width].
  double horizontalFov(double width) => 2 * math.atan(width / 2 / focalPixels);

  @override
  void projectAll(Float64List xyz, Float32List screen, Float64List depth) {
    final s = _sin, c = _cos;
    final ex = eye.x, ey = eye.y, ez = eye.z;
    final f = focalPixels, cx = center.dx, cy = center.dy;
    for (var v = 0; v < depth.length; v++) {
      final dx = xyz[v * 3] - ex;
      final dy = xyz[v * 3 + 1] - ey;
      final dz = xyz[v * 3 + 2] - ez;
      final d = dx * c - dz * s;
      depth[v] = d;
      if (d > 1e-6) {
        final up = dx * s + dz * c;
        screen[v * 2] = cx - f * dy / d;
        screen[v * 2 + 1] = cy - f * up / d;
      }
    }
  }
}

/// Orthographic bird's-eye camera. Ego front bumper sits at 70 % height.
class TopDownCamera extends SceneCamera {
  TopDownCamera(Size size)
    : scale = math.min(size.width / 14, size.height / 55),
      origin = Offset(size.width / 2, size.height * 0.70);

  final double scale;
  final Offset origin;

  @override
  double get nearDepth => -1e9;

  /// Pseudo depth so far-forward points are "farther" for ordering/fog.
  @override
  double depthOf(V3 point) => 40 + point.x - point.z * 0.01;

  @override
  ProjectedPoint? project(V3 point) => ProjectedPoint(
    Offset(origin.dx - point.y * scale, origin.dy - point.x * scale),
    depthOf(point),
  );

  @override
  double? get horizonY => null;

  @override
  double pixelsPerMeter(double depth) => scale;

  @override
  bool faceVisible(V3 center, V3 normal) => normal.z > 1e-6;

  @override
  V3? get eyePoint => null;

  @override
  void projectAll(Float64List xyz, Float32List screen, Float64List depth) {
    for (var v = 0; v < depth.length; v++) {
      final x = xyz[v * 3], y = xyz[v * 3 + 1], z = xyz[v * 3 + 2];
      screen[v * 2] = origin.dx - y * scale;
      screen[v * 2 + 1] = origin.dy - x * scale;
      depth[v] = 40 + x - z * 0.01;
    }
  }
}

double _lerp(double a, double b, double t) => a + (b - a) * t;
