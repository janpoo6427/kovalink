import "dart:math" as math;
import "dart:ui";

import "package:flutter_test/flutter_test.dart";
import "package:kovalink/src/features/road_view/scene3d/scene_camera.dart";
import "package:kovalink/src/features/road_view/scene3d/scene_director.dart";
import "package:kovalink/src/models/ego_vehicle_profile.dart";

// Historical framing, intentionally independent of the new distance default.
PerspectiveCamera _previous(Size size, {double? speed}) {
  final aspect = (size.width / size.height).clamp(0.45, 1.8);
  final t = ((aspect - 0.5) / 1.0).clamp(0.0, 1.0);
  double lerp(double a, double b, double u) => a + (b - a) * u;
  if (speed == null) {
    return PerspectiveCamera.framed(
      size,
      egoWidthFraction: lerp(0.24, 0.17, t),
      horizonFraction: lerp(0.42, 0.46, t),
      contactFraction: lerp(0.80, 0.85, t),
      distance: 9,
    );
  }
  final s = (speed / 30).clamp(0.0, 1.0);
  return PerspectiveCamera.framed(
    size,
    egoWidthFraction: lerp(lerp(0.36, 0.205, t), lerp(0.31, 0.175, t), s),
    horizonFraction: lerp(lerp(0.50, 0.455, t), lerp(0.48, 0.44, t), s),
    contactFraction: lerp(lerp(0.80, 0.87, t), lerp(0.795, 0.865, t), s),
    distance: lerp(8.6, 9.2, s),
  );
}

Rect _bounds(
  SceneCamera camera, {
  double rear = -4.5,
  double left = 0,
  double length = 4.5,
  double width = 1.86,
  double height = 1.48,
}) {
  final points = [
    for (final x in [rear, rear + length])
      for (final y in [left - width / 2, left + width / 2])
        for (final z in [0.0, height]) camera.project(V3(x, y, z))!.offset,
  ];
  return Rect.fromLTRB(
    points.map((p) => p.dx).reduce(math.min),
    points.map((p) => p.dy).reduce(math.min),
    points.map((p) => p.dx).reduce(math.max),
    points.map((p) => p.dy).reduce(math.max),
  );
}

void main() {
  for (final size in const [
    Size(1080, 2340),
    Size(1080, 1920),
    Size(1081, 1200),
    Size(1396, 1099),
    Size(1920, 1080),
  ]) {
    for (final speed in <double?>[null, 0, 15, 30]) {
      final name = speed == null ? "plain" : "hero $speed m/s";
      final camera = speed == null
          ? PerspectiveCamera.chase(size)
          : SceneDirector.chaseCamera(size, speed);
      final old = _previous(size, speed: speed);
      final viewport = Offset.zero & size;

      test(
        "$name at $size: ego shrinks 25-35%, eye retreats, anchors stay",
        () {
          for (final body in [(4.5, 1.86, 1.48), (5.2, 2.0, 1.8)]) {
            final before = _bounds(
              old,
              rear: -body.$1,
              length: body.$1,
              width: body.$2,
              height: body.$3,
            );
            final after = _bounds(
              camera,
              rear: -body.$1,
              length: body.$1,
              width: body.$2,
              height: body.$3,
            );
            expect(after.width / before.width, inInclusiveRange(0.65, 0.75));
            expect(viewport.contains(after.topLeft), isTrue);
            expect(viewport.contains(after.bottomRight), isTrue);
          }
          expect(camera.eye.x, lessThan(old.eye.x - 3));
          expect(camera.focalPixels, closeTo(old.focalPixels, 1e-9));
          expect(camera.pitchRadians, closeTo(old.pitchRadians, 1e-9));
          expect(camera.horizonY, closeTo(old.horizonY, 1e-9));
          expect(
            camera.project(const V3(-4.5, 0, 0))!.offset.dy,
            closeTo(old.project(const V3(-4.5, 0, 0))!.offset.dy, 1e-9),
          );
        },
      );

      test("$name at $size: adjacent-lane geometry has more visible area", () {
        // Projection fixtures only, not generated detections. Both 3D
        // renderers currently admit object rear positions down to -6 m.
        // Portrait hero framing does not fit every corner of a close car;
        // require its center and increased visible body area, not 360 coverage.
        for (final left in [-3.6, 3.6]) {
          final before = _bounds(old, rear: -6, left: left);
          final after = _bounds(camera, rear: -6, left: left);
          final center = camera.project(V3(-3.75, left, 0.74))!.offset;
          expect(viewport.contains(center), isTrue);
          double visibleFraction(Rect r) {
            final visible = r.intersect(viewport);
            return math.max(0, visible.width) *
                math.max(0, visible.height) /
                (r.width * r.height);
          }

          final visible = visibleFraction(after);
          expect(visible, greaterThanOrEqualTo(0.4));
          expect(visible, greaterThanOrEqualTo(visibleFraction(before)));
          if (visibleFraction(before) < 0.95) {
            expect(visible, greaterThan(visibleFraction(before) + 0.1));
          }
          final ahead = _bounds(camera, rear: 8, left: left);
          expect(viewport.contains(ahead.topLeft), isTrue);
          expect(viewport.contains(ahead.bottomRight), isTrue);
        }
      });
    }

    test("driver and top-down projections remain unchanged at $size", () {
      final driver =
          SceneCamera.forViewpoint(
                SceneViewpoint.driver,
                size,
                EgoVehicleProfile.builtIn,
              )
              as PerspectiveCamera;
      expect(driver.eye.x, -4.5 * 0.42);
      expect(driver.eye.y, 0.37);
      expect(driver.eye.z, 1.3);
      expect(driver.pitchRadians, 0.02);
      expect(driver.focalPixels, size.width * 0.78);
      expect(driver.nearDepth, 0.3);
      expect(driver.center, Offset(size.width / 2, size.height / 2));
      final top =
          SceneCamera.forViewpoint(
                SceneViewpoint.topDown,
                size,
                EgoVehicleProfile.builtIn,
              )
              as TopDownCamera;
      expect(top.scale, math.min(size.width / 14, size.height / 55));
      expect(top.origin, Offset(size.width / 2, size.height * 0.70));
      expect(
        top.project(const V3(10, 2, 0))!.offset,
        Offset(top.origin.dx - 2 * top.scale, top.origin.dy - 10 * top.scale),
      );
    });
  }
}
