import 'dart:math' as math;

import 'package:kovalink/src/models/road_scene.dart';

/// Built-in demo drives (설정 → 데모 경로).
enum DemoRoute { city, highway }

/// What the demo is currently showing. Exposed for tests and the HUD label.
enum DemoPhase {
  stopped,
  straight,
  curve,
  leadApproach,
  laneChange,
  approachTurn,
}

/// Deterministic, network-free fake drive that produces [RoadScene] frames.
///
/// The whole loop is a pure function of `(route, seed, elapsed)`: the same
/// inputs always give the same frame, so tests and screenshots are stable.
/// The seed only varies background traffic and small jitter; the scripted
/// events (stop, curve, lead approach, lane change, turn) are fixed.
///
/// Display only: nothing here talks to a vehicle.
class DemoDriveScenario {
  DemoDriveScenario({this.route = DemoRoute.city, this.seed = defaultSeed}) {
    final random = math.Random(seed);
    _noise = List.generate(
      64,
      (_) => random.nextDouble() * 2 - 1,
      growable: false,
    );
    _traffic = List.generate(_trafficCount, (index) {
      final lanes = route == DemoRoute.city
          ? _cityTrafficLanes
          : _highwayTrafficLanes;
      final lane = lanes[random.nextInt(lanes.length)];
      final oncoming = lane > (route == DemoRoute.city ? 5.0 : 6.0);
      final base = route == DemoRoute.city ? 11.0 : 26.0;
      return _Traffic(
        id: 100 + index,
        lateral: lane,
        start: random.nextDouble() * _trafficWindow,
        speed: oncoming
            ? -(base * (0.8 + random.nextDouble() * 0.4))
            : base * (0.75 + random.nextDouble() * 0.45),
        truck: route == DemoRoute.highway && random.nextDouble() < 0.25,
      );
    }, growable: false);
    _precomputeMotion();
  }

  static const defaultSeed = 20261124;
  static const period = Duration(seconds: 90);
  static const _step = 0.05;
  static const _trafficCount = 7;
  static const _trafficWindow = 190.0;

  // World lateral positions (m, left positive) relative to the starting lane.
  static const _cityLines = [-1.7, 1.7, 5.1];
  static const _cityEdges = [-3.6, 11.9];
  static const _cityTrafficLanes = [0.0, 3.4, 8.5, 11.9 - 1.7];
  static const _highwayLines = [-5.4, -1.8, 1.8, 5.4];
  static const _highwayEdges = [-8.4, 6.4];
  static const _highwayTrafficLanes = [-3.6, 0.0, 3.6];

  final DemoRoute route;
  final int seed;
  late final List<double> _noise;
  late final List<_Traffic> _traffic;
  late final List<double> _odometer;

  double get _seconds => period.inMilliseconds / 1000;

  /// Distance covered in one full loop, meters.
  double get loopDistance => _odometer.last;

  void _precomputeMotion() {
    final steps = (_seconds / _step).round();
    final odometer = List<double>.filled(steps + 1, 0);
    for (var index = 1; index <= steps; index++) {
      final t0 = (index - 1) * _step;
      // Trapezoid integration of the scripted speed profile.
      odometer[index] =
          odometer[index - 1] + (speedAt(t0) + speedAt(t0 + _step)) * _step / 2;
    }
    _odometer = odometer;
  }

  /// Scripted ego speed, m/s, at [t] seconds into the loop.
  double speedAt(double t) => switch (route) {
    DemoRoute.city =>
      t < 6
          ? 0
          : t < 38
          ? _ramp(t, 6, 12, 0, 11.1)
          : t < 50
          ? _ramp(t, 38, 48, 11.1, 6.0)
          : t < 76
          ? _ramp(t, 52, 60, 6.0, 11.1)
          : _ramp(t, 76, 89, 11.1, 0),
    DemoRoute.highway =>
      t < 35
          ? _ramp(t, 0, 8, 24, 27.8)
          : t < 50
          ? _ramp(t, 35, 47, 27.8, 22)
          : t < 75
          ? _ramp(t, 50, 60, 22, 27.8)
          : _ramp(t, 80, 90, 27.8, 24),
  };

  double _odometerAt(double t) {
    final position = t / _step;
    final index = position.floor().clamp(0, _odometer.length - 2);
    final fraction = position - index;
    return _odometer[index] +
        (_odometer[index + 1] - _odometer[index]) * fraction;
  }

  DemoPhase phaseAt(Duration elapsed) {
    final t = _loopSeconds(elapsed);
    return switch (route) {
      DemoRoute.city =>
        t < 6
            ? DemoPhase.stopped
            : t < 20
            ? DemoPhase.straight
            : t < 38
            ? DemoPhase.curve
            : t < 52
            ? DemoPhase.leadApproach
            : t < 66
            ? DemoPhase.laneChange
            : DemoPhase.approachTurn,
      DemoRoute.highway =>
        t < 15
            ? DemoPhase.straight
            : t < 35
            ? DemoPhase.curve
            : t < 50
            ? DemoPhase.leadApproach
            : t < 62
            ? DemoPhase.laneChange
            : DemoPhase.straight,
    };
  }

  double _loopSeconds(Duration elapsed) {
    final ms = elapsed.inMilliseconds % period.inMilliseconds;
    return ms / 1000;
  }

  /// Road curvature (1/m, left positive) at loop time [t].
  double curvatureAt(double t) => switch (route) {
    DemoRoute.city =>
      t >= 20 && t < 38 ? -0.0065 * math.sin(math.pi * (t - 20) / 18) : 0,
    DemoRoute.highway =>
      t >= 15 && t < 35 ? 0.0016 * math.sin(math.pi * (t - 15) / 20) : 0,
  };

  /// Ego lateral position in world lane coordinates (0 = starting lane).
  double egoLateralAt(double t) => switch (route) {
    DemoRoute.city => _ramp(t, 53, 60, 0, 3.4),
    DemoRoute.highway => _ramp(t, 51, 58, 0, 3.6),
  };

  /// Lane the ego is heading to (world lateral of its center).
  double _targetLaneAt(double t) => switch (route) {
    DemoRoute.city => t >= 52 ? 3.4 : 0,
    DemoRoute.highway => t >= 50 ? 3.6 : 0,
  };

  RoadScene sceneAt(Duration elapsed) {
    final t = _loopSeconds(elapsed);
    final city = route == DemoRoute.city;
    final speed = speedAt(t);
    final odometer = _odometerAt(t);
    final curvature = curvatureAt(t);
    final ego = egoLateralAt(t);
    final target = _targetLaneAt(t) - ego;
    double bend(double x) => 0.5 * curvature * x * x;

    List<ScenePoint> line(double worldLateral) => [
      for (var x = 0.0; x <= 150; x += 10)
        ScenePoint(forwardMeters: x, leftMeters: worldLateral - ego + bend(x)),
    ];

    final lines = city ? _cityLines : _highwayLines;
    final laneLines = <LaneLine>[
      for (final (index, lateral) in lines.indexed)
        LaneLine(
          points: line(lateral),
          probability: (0.9 + 0.08 * _noise[index]).clamp(0.0, 1.0),
          color: index == lines.length - 1
              ? LaneLineColor.yellow
              : LaneLineColor.white,
          style: index == lines.length - 1
              ? (city ? LaneLineStyle.doubleSolid : LaneLineStyle.solid)
              : index == 0
              ? LaneLineStyle.solid
              : LaneLineStyle.dashed,
        ),
    ];
    final edges = city ? _cityEdges : _highwayEdges;
    final path = [
      for (var x = 0.0; x <= 120; x += 6)
        ScenePoint(
          forwardMeters: x,
          leftMeters: bend(x) + target * _smooth(x / 28),
        ),
    ];

    final objects = <TrackedObject>[
      ..._leadVehicles(t, ego, bend),
      ..._backgroundTraffic(odometer, ego, _targetLaneAt(t), bend),
      if (city) ..._cones(odometer, ego, bend),
    ];

    final braking = city
        ? (t < 6 || (t >= 44 && t < 50) || t >= 82)
        : (t >= 42 && t < 47);
    final changingLanes = city ? t >= 51 && t < 60 : t >= 49 && t < 58;
    final turning = city && t >= 78;
    final remaining = math.max(0.0, (city ? 31700.0 : 17500.0) - odometer);
    final turnDistance = math.max(0.0, loopDistance + 30 - odometer);

    return RoadScene(
      monotonicTimeNanos: elapsed.inMicroseconds * 1000,
      speedMps: speed,
      setSpeedMps: city ? 50 / 3.6 : 100 / 3.6,
      steeringAngleDegrees:
          curvature * 2.8 * 15 * 180 / math.pi + (changingLanes ? 4 : 0),
      engaged: !(city && t < 6),
      gear: VehicleGear.drive,
      leftBlinker: changingLanes || turning,
      rightBlinker: false,
      brakeActive: braking,
      speedLimitKph: city ? (t < 66 ? 50 : 40) : 100,
      roadType: city ? RoadType.city : RoadType.highway,
      roadName: city ? '서울대학로' : '경부고속도로',
      odometerMeters: odometer,
      plannedPath: path,
      leftLane: const [],
      rightLane: const [],
      laneLines: laneLines,
      roadEdges: [for (final edge in edges) line(edge)],
      objects: objects,
      tbt: city
          ? TbtInstruction(
              maneuver: TbtManeuver.turnLeft,
              distanceMeters: turnDistance,
              roadName: '서울대학로278번길',
              nextManeuver: TbtManeuver.turnRight,
              nextDistanceMeters: turnDistance + 231,
              remainingDistanceMeters: remaining,
              remainingSeconds: (remaining / 9).round(),
            )
          : TbtInstruction(
              maneuver: TbtManeuver.straight,
              distanceMeters: math.max(0.0, 9000 - odometer),
              roadName: '경부고속도로',
              remainingDistanceMeters: remaining,
              remainingSeconds: (remaining / 24).round(),
            ),
      trafficSignal: city ? _signal(t, odometer) : null,
      roadAlerts: city ? const [] : _alerts(odometer),
      laneGuidance: city && turnDistance < 400
          ? const [
              LaneGuide(directions: [LaneDirection.left], recommended: true),
              LaneGuide(directions: [LaneDirection.straight]),
              LaneGuide(
                directions: [LaneDirection.straight, LaneDirection.right],
              ),
            ]
          : const [],
    );
  }

  Iterable<TrackedObject> _leadVehicles(
    double t,
    double ego,
    double Function(double) bend,
  ) sync* {
    final jitter = 0.15 * _noise[(t * 4).floor() % _noise.length];
    // The scripted lead switches to car 2 once the ego crosses into the
    // left lane during the lane change.
    final leadId = route == DemoRoute.city
        ? (t < 56.5 ? 1 : 2)
        : (t < 54.5 ? 1 : 2);
    TrackedObject car(
      int id,
      double gap,
      double lane, {
      bool brake = false,
      double relative = 0,
    }) => TrackedObject(
      id: id,
      distanceMeters: gap + jitter,
      leftMeters: lane - ego + bend(gap),
      relativeSpeedMps: relative,
      brakeLights: brake,
      isLead: id == leadId,
    );

    if (route == DemoRoute.city) {
      // Car 1 shares the starting lane; car 2 is ahead in the left lane.
      final gap1 = t < 6
          ? 6.0
          : t < 20
          ? _ramp(t, 6, 20, 6, 20)
          : t < 38
          ? 20 + 2 * math.sin((t - 20) / 3)
          : t < 52
          ? _ramp(t, 38, 50, 22, 9)
          : _ramp(t, 52, 66, 9, 30);
      yield car(
        1,
        gap1,
        0,
        brake: t < 6 || (t >= 38 && t < 48),
        relative: t >= 38 && t < 50 ? -1.2 : 0,
      );
      final gap2 = t < 52
          ? 34.0 + 3 * math.sin(t / 5)
          : _ramp(t, 52, 89, 26, 7);
      yield car(2, gap2, 3.4, brake: t >= 80, relative: t >= 76 ? -0.8 : 0);
    } else {
      final gap1 = t < 35
          ? 36 + 2 * math.sin(t / 4)
          : t < 50
          ? _ramp(t, 35, 47, 36, 21)
          : _ramp(t, 50, 62, 21, -12);
      yield car(
        1,
        gap1,
        0,
        brake: t >= 41 && t < 47,
        relative: t >= 35 && t < 47 ? -2.2 : 0,
      );
      final gap2 = t < 50 ? 60.0 : _ramp(t, 50, 75, 60, 34.8);
      yield car(2, gap2, 3.6, relative: t >= 62 ? -0.5 : 0);
    }
  }

  Iterable<TrackedObject> _backgroundTraffic(
    double odometer,
    double ego,
    double targetLane,
    double Function(double) bend,
  ) sync* {
    for (final car in _traffic) {
      // Scripted cars own the ego and target lanes; background traffic uses
      // the others.
      if ((car.lateral - ego).abs() < 1.8 ||
          (car.lateral - targetLane).abs() < 1.8) {
        continue;
      }
      // Each car moves at its own speed through a wrapping window.
      final world =
          car.start +
          car.speed * (odometer / math.max(1.0, _averageSpeed)) -
          odometer;
      final gap =
          (world % _trafficWindow + _trafficWindow) % _trafficWindow - 30;
      yield TrackedObject(
        id: car.id,
        distanceMeters: gap,
        leftMeters: car.lateral - ego + bend(gap.abs()),
        relativeSpeedMps: car.speed,
        kind: car.truck ? TrackedObjectKind.truck : TrackedObjectKind.vehicle,
      );
    }
  }

  double get _averageSpeed => loopDistance / _seconds;

  Iterable<TrackedObject> _cones(
    double odometer,
    double ego,
    double Function(double) bend,
  ) sync* {
    // Work zone on the right shoulder, passed during the curve.
    final start = _odometerAt(24) + 25;
    for (var index = 0; index < 9; index++) {
      final gap = start + index * 7 - odometer;
      if (gap < -10 || gap > 140) continue;
      yield TrackedObject(
        id: 500 + index,
        distanceMeters: gap,
        leftMeters: -2.6 - ego + bend(math.max(0.0, gap)),
        relativeSpeedMps: 0,
        kind: TrackedObjectKind.trafficCone,
      );
    }
  }

  TrafficSignal? _signal(double t, double odometer) {
    if (t < 6) {
      return TrafficSignal(
        state: TrafficSignalState.red,
        remainingSeconds: (6 - t).ceil(),
        distanceMeters: _odometer.first + 12 - odometer,
      );
    }
    if (t < 9) {
      return TrafficSignal(
        state: TrafficSignalState.green,
        leftArrow: true,
        remainingSeconds: (30 - t).ceil(),
        distanceMeters: math.max(0.0, 12 - odometer),
      );
    }
    if (t < 60) return null;
    final distance = loopDistance + 12 - odometer;
    final state = t < 78
        ? TrafficSignalState.green
        : t < 81
        ? TrafficSignalState.yellow
        : TrafficSignalState.red;
    final remaining = switch (state) {
      TrafficSignalState.green => (78 - t).ceil(),
      TrafficSignalState.yellow => (81 - t).ceil(),
      _ => (96 - t).ceil(),
    };
    return TrafficSignal(
      state: state,
      leftArrow: state == TrafficSignalState.green,
      remainingSeconds: remaining,
      distanceMeters: distance,
    );
  }

  List<RoadAlert> _alerts(double odometer) {
    final camera = _odometerAt(82) - odometer;
    final toll = loopDistance + 600 - odometer;
    return [
      if (camera > 0)
        RoadAlert(
          kind: RoadAlertKind.speedCamera,
          distanceMeters: camera,
          speedLimitKph: 100,
        ),
      RoadAlert(kind: RoadAlertKind.tollgate, distanceMeters: toll),
    ];
  }

  static double _smooth(double u) {
    final x = u.clamp(0.0, 1.0);
    return x * x * (3 - 2 * x);
  }

  static double _ramp(double t, double t0, double t1, double a, double b) =>
      a + (b - a) * _smooth((t - t0) / (t1 - t0));
}

class _Traffic {
  const _Traffic({
    required this.id,
    required this.lateral,
    required this.start,
    required this.speed,
    required this.truck,
  });

  final int id;
  final double lateral;
  final double start;
  final double speed;
  final bool truck;
}
