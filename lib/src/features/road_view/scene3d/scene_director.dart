import 'dart:math' as math;
import 'dart:ui';

import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/gpu_scene/road_world_glb.dart' show PathStyle;
import 'package:kovalink/src/models/ego_vehicle_profile.dart';
import 'package:kovalink/src/models/road_scene.dart';

/// A vehicle in a blind spot beside the ego (display only).
class BlindSpotMark {
  const BlindSpotMark({
    required this.left,
    required this.strength,
    this.object,
  });

  /// True for the left side.
  final bool left;

  /// 0..1 (fades in and out smoothly).
  final double strength;
  final TrackedObject? object;
}

/// Everything the renderers need for one frame of "camera work": the
/// camera, its roll, the path-ribbon styling and overlay marks.
class DirectorFrame {
  const DirectorFrame({
    required this.camera,
    this.rollRadians = 0,
    this.path = const PathStyle(),
    this.blindSpots = const [],
    this.leadTone = 0,
  });

  final SceneCamera camera;

  /// Screen roll (positive = horizon tilts counter-clockwise), radians.
  final double rollRadians;
  final PathStyle path;
  final List<BlindSpotMark> blindSpots;

  /// 0 = lead far/none (calm blue), 1 = close (red).
  final double leadTone;
}

/// Stateful "camera operator" shared by the GPU and software renderers.
///
/// It turns plain [RoadScene] frames into smooth motion: the chase camera
/// rises and widens with speed, leans a little into announced turns, the
/// path ribbon gets a light sweep when steering assist engages and shifts
/// color as the lead closes in, and vehicles beside the ego raise blind
/// spot marks. All values are filtered with frame-rate independent
/// exponential smoothing on the scene's own clock, so captures replaying
/// the same frames are deterministic. Display only.
class SceneDirector {
  SceneDirector();

  int? _lastNanos;
  double _speed = 0;
  double _roll = 0;
  double _tone = 0;
  bool? _engaged;
  double _sweepStart = -1;
  double _clock = 0;
  final _blind = <bool, double>{true: 0, false: 0};
  final _blindObject = <bool, TrackedObject?>{};

  /// Forget history (next frame snaps to its steady state).
  void reset() {
    _lastNanos = null;
    _engaged = null;
    _sweepStart = -1;
  }

  static const sweepSeconds = 1.4;

  DirectorFrame update(
    RoadScene scene,
    Size size, {
    SceneViewpoint viewpoint = SceneViewpoint.chase,
    EgoVehicleProfile vehicle = EgoVehicleProfile.builtIn,
  }) {
    final nanos = scene.monotonicTimeNanos;
    final last = _lastNanos;
    final dt = last == null
        ? double.infinity
        : ((nanos - last) / 1e9).clamp(0.0, 0.5);
    _lastNanos = nanos;
    final snap = dt.isInfinite;
    if (!snap) _clock += dt;
    double follow(double current, double target, double tau) => snap
        ? target
        : current + (target - current) * (1 - math.exp(-dt / tau));

    _speed = follow(_speed, scene.speedMps, 1.2);
    _roll = follow(_roll, _targetRoll(scene), 0.7);
    _tone = follow(_tone, leadToneFor(scene), 0.45);

    // Engage sweep: starts when steering assist turns on.
    if (_engaged == false && scene.engaged) _sweepStart = _clock;
    _engaged = scene.engaged;
    var sweep = -1.0;
    if (_sweepStart >= 0) {
      final u = (_clock - _sweepStart) / sweepSeconds;
      if (u <= 1) {
        sweep = u;
      } else {
        _sweepStart = -1;
      }
    }

    final marks = <BlindSpotMark>[];
    for (final left in const [true, false]) {
      final hit = blindSpotObject(scene, left: left, vehicle: vehicle);
      if (hit != null) _blindObject[left] = hit;
      _blind[left] = follow(_blind[left]!, hit == null ? 0 : 1, 0.25);
      if (_blind[left]! > 0.02) {
        marks.add(
          BlindSpotMark(
            left: left,
            strength: _blind[left]!,
            object: hit ?? _blindObject[left],
          ),
        );
      }
    }

    final camera = switch (viewpoint) {
      SceneViewpoint.chase => chaseCamera(size, _speed),
      _ => SceneCamera.forViewpoint(viewpoint, size, vehicle),
    };
    return DirectorFrame(
      camera: camera,
      rollRadians: viewpoint == SceneViewpoint.chase ? _roll : 0,
      path: PathStyle(leadTone: _tone, sweep: sweep, engaged: scene.engaged),
      blindSpots: marks,
      leadTone: _tone,
    );
  }

  /// Hero chase framing: the ego is the subject, a little lower and
  /// larger than a plain follow camera, rising and widening with speed.
  /// Both chase modes step back to expose more surrounding road users.
  /// Portrait screens get a lower, flatter camera so the road is not seen
  /// from too high above.
  static PerspectiveCamera chaseCamera(Size size, double speedMps) {
    final aspect = (size.width / size.height).clamp(0.45, 1.8);
    final t = ((aspect - 0.5) / 1.0).clamp(0.0, 1.0);
    final s = (speedMps / 30).clamp(0.0, 1.0);
    double lerp(double a, double b, double u) => a + (b - a) * u;
    return PerspectiveCamera.framed(
      size,
      egoWidthFraction:
          lerp(lerp(0.36, 0.205, t), lerp(0.31, 0.175, t), s) *
          PerspectiveCamera.chaseFramingScale,
      horizonFraction: lerp(lerp(0.50, 0.455, t), lerp(0.48, 0.44, t), s),
      contactFraction: lerp(lerp(0.80, 0.87, t), lerp(0.795, 0.865, t), s),
      distance: lerp(8.6, 9.2, s) / PerspectiveCamera.chaseFramingScale,
    );
  }

  /// Lead closeness tone from time-gap and distance.
  static double leadToneFor(RoadScene scene) {
    final lead = scene.leadObject;
    if (lead == null || lead.distanceMeters <= 0) return 0;
    final v = math.max(scene.speedMps, 0.0);
    // Calm beyond ~1.3 s time gap, red at ~0.6 s (and within 5–14 m in
    // slow traffic).
    final safe = math.max(14.0, v * 1.3);
    final danger = math.max(5.0, v * 0.6);
    return ((safe - lead.distanceMeters) / (safe - danger)).clamp(0.0, 1.0);
  }

  /// A vehicle (or cyclist) in the adjacent lane beside or just behind the
  /// ego on the given side, if any.
  static TrackedObject? blindSpotObject(
    RoadScene scene, {
    required bool left,
    EgoVehicleProfile vehicle = EgoVehicleProfile.builtIn,
  }) {
    final egoLength = vehicle.dimensions.length;
    TrackedObject? best;
    for (final o in scene.objects) {
      if (o.kind != TrackedObjectKind.vehicle &&
          o.kind != TrackedObjectKind.truck &&
          o.kind != TrackedObjectKind.cyclist) {
        continue;
      }
      final lateral = o.leftMeters - scene.pathLeftAt(0);
      if (left
          ? (lateral < 1.9 || lateral > 5.6)
          : (lateral > -1.9 || lateral < -5.6)) {
        continue;
      }
      final front = o.distanceMeters + o.length;
      // Overlaps the zone from 7 m behind the ego's rear bumper to its
      // front bumper.
      if (front < -egoLength - 7 || o.distanceMeters > 0.5) continue;
      if (best == null || o.distanceMeters > best.distanceMeters) best = o;
    }
    return best;
  }

  double _targetRoll(RoadScene scene) {
    const maxRoll = 2.6 * math.pi / 180;
    var roll = 0.0;
    final tbt = scene.tbt;
    if (tbt != null && tbt.distanceMeters < 140) {
      final dir = switch (tbt.maneuver) {
        TbtManeuver.turnLeft ||
        TbtManeuver.slightLeft ||
        TbtManeuver.uTurn => 1.0,
        TbtManeuver.turnRight || TbtManeuver.slightRight => -1.0,
        _ => 0.0,
      };
      final d = tbt.distanceMeters;
      // Builds up approaching the turn, eases off right at it.
      final k = d > 25 ? (140 - d) / 115 : d / 25;
      roll +=
          dir *
          maxRoll *
          k.clamp(0.0, 1.0) *
          (tbt.maneuver == TbtManeuver.slightLeft ||
                  tbt.maneuver == TbtManeuver.slightRight
              ? 0.5
              : 1);
    }
    // Lean slightly with the road curvature (steering), like a camera car.
    roll += (scene.steeringAngleDegrees / 90).clamp(-1.0, 1.0) * maxRoll * 0.35;
    return roll.clamp(-maxRoll, maxRoll);
  }
}
