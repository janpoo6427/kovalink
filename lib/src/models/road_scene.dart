import 'dart:math' as math;

class ScenePoint {
  const ScenePoint({
    required this.forwardMeters,
    required this.leftMeters,
    this.upMeters = 0,
  });

  final double forwardMeters;
  final double leftMeters;
  final double upMeters;

  factory ScenePoint.fromJson(Map<String, dynamic> json) => ScenePoint(
    forwardMeters: (json['x'] as num).toDouble(),
    leftMeters: (json['y'] as num).toDouble(),
    upMeters: (json['z'] as num? ?? 0).toDouble(),
  );
}

class CameraProjection {
  const CameraProjection({
    required this.matrix,
    required this.sourceWidth,
    required this.sourceHeight,
  }) : assert(matrix.length == 12);

  final List<double> matrix;
  final double sourceWidth;
  final double sourceHeight;

  factory CameraProjection.fromJson(Map<String, dynamic> json) {
    final matrix = (json['matrix3x4'] as List<dynamic>)
        .map((value) => (value as num).toDouble())
        .toList(growable: false);
    if (matrix.length != 12) {
      throw const FormatException(
        'cameraProjection.matrix3x4 must contain 12 values',
      );
    }
    return CameraProjection(
      matrix: matrix,
      sourceWidth: (json['sourceWidth'] as num).toDouble(),
      sourceHeight: (json['sourceHeight'] as num).toDouble(),
    );
  }
}

enum TrackedObjectKind { vehicle, pedestrian, unknown }

enum VehicleGear { park, reverse, neutral, drive, unknown }

enum TbtManeuver {
  straight,
  turnLeft,
  turnRight,
  slightLeft,
  slightRight,
  uTurn,
  arrive,
  unknown,
}

class TbtInstruction {
  const TbtInstruction({
    required this.maneuver,
    required this.distanceMeters,
    this.roadName,
    this.nextManeuver,
    this.nextDistanceMeters,
    this.remainingDistanceMeters,
    this.remainingSeconds,
  });

  final TbtManeuver maneuver;
  final double distanceMeters;
  final String? roadName;
  final TbtManeuver? nextManeuver;
  final double? nextDistanceMeters;
  final double? remainingDistanceMeters;
  final int? remainingSeconds;

  factory TbtInstruction.fromJson(Map<String, dynamic> json) => TbtInstruction(
    maneuver: _enumByName(
      TbtManeuver.values,
      json['maneuver'] as String?,
      TbtManeuver.unknown,
    ),
    distanceMeters: (json['distanceMeters'] as num).toDouble(),
    roadName: json['roadName'] as String?,
    nextManeuver: switch (json['nextManeuver']) {
      String value => _enumByName(
        TbtManeuver.values,
        value,
        TbtManeuver.unknown,
      ),
      _ => null,
    },
    nextDistanceMeters: (json['nextDistanceMeters'] as num?)?.toDouble(),
    remainingDistanceMeters: (json['remainingDistanceMeters'] as num?)
        ?.toDouble(),
    remainingSeconds: (json['remainingSeconds'] as num?)?.toInt(),
  );
}

class TrackedObject {
  const TrackedObject({
    required this.distanceMeters,
    required this.leftMeters,
    required this.relativeSpeedMps,
    this.kind = TrackedObjectKind.vehicle,
  });

  final double distanceMeters;
  final double leftMeters;
  final double relativeSpeedMps;
  final TrackedObjectKind kind;

  factory TrackedObject.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'] as String? ?? 'unknown';
    return TrackedObject(
      distanceMeters: (json['distanceMeters'] as num).toDouble(),
      leftMeters: (json['leftMeters'] as num).toDouble(),
      relativeSpeedMps: (json['relativeSpeedMps'] as num? ?? 0).toDouble(),
      kind: TrackedObjectKind.values.firstWhere(
        (value) => value.name == kindName,
        orElse: () => TrackedObjectKind.unknown,
      ),
    );
  }
}

class RoadScene {
  const RoadScene({
    required this.monotonicTimeNanos,
    required this.speedMps,
    required this.setSpeedMps,
    required this.steeringAngleDegrees,
    required this.engaged,
    required this.plannedPath,
    required this.leftLane,
    required this.rightLane,
    required this.objects,
    this.gear = VehicleGear.unknown,
    this.leftBlinker = false,
    this.rightBlinker = false,
    this.brakeActive = false,
    this.speedLimitKph,
    this.tbt,
    this.cameraProjection,
  });

  final int monotonicTimeNanos;
  final double speedMps;
  final double setSpeedMps;
  final double steeringAngleDegrees;
  final bool engaged;
  final List<ScenePoint> plannedPath;
  final List<ScenePoint> leftLane;
  final List<ScenePoint> rightLane;
  final List<TrackedObject> objects;
  final VehicleGear gear;
  final bool leftBlinker;
  final bool rightBlinker;
  final bool brakeActive;
  final double? speedLimitKph;
  final TbtInstruction? tbt;
  final CameraProjection? cameraProjection;

  double get speedKph => speedMps * 3.6;
  double get setSpeedKph => setSpeedMps * 3.6;

  factory RoadScene.fromJson(Map<String, dynamic> json) {
    List<ScenePoint> points(String key) =>
        (json[key] as List<dynamic>? ?? const [])
            .map((value) => ScenePoint.fromJson(value as Map<String, dynamic>))
            .toList(growable: false);

    return RoadScene(
      monotonicTimeNanos: (json['monotonicTimeNanos'] as num).toInt(),
      speedMps: (json['speedMps'] as num).toDouble(),
      setSpeedMps: (json['setSpeedMps'] as num? ?? 0).toDouble(),
      steeringAngleDegrees: (json['steeringAngleDegrees'] as num? ?? 0)
          .toDouble(),
      engaged: json['engaged'] as bool? ?? false,
      gear: _enumByName(
        VehicleGear.values,
        json['gear'] as String?,
        VehicleGear.unknown,
      ),
      leftBlinker: json['leftBlinker'] as bool? ?? false,
      rightBlinker: json['rightBlinker'] as bool? ?? false,
      brakeActive: json['brakeActive'] as bool? ?? false,
      speedLimitKph: (json['speedLimitKph'] as num?)?.toDouble(),
      tbt: switch (json['tbt']) {
        Map<String, dynamic> value => TbtInstruction.fromJson(value),
        _ => null,
      },
      plannedPath: points('plannedPath'),
      leftLane: points('leftLane'),
      rightLane: points('rightLane'),
      objects: (json['objects'] as List<dynamic>? ?? const [])
          .map((value) => TrackedObject.fromJson(value as Map<String, dynamic>))
          .toList(growable: false),
      cameraProjection: switch (json['cameraProjection']) {
        Map<String, dynamic> value => CameraProjection.fromJson(value),
        _ => null,
      },
    );
  }

  factory RoadScene.demo(Duration elapsed) {
    final seconds = elapsed.inMilliseconds / 1000;
    final curve = math.sin(seconds * 0.32) * 0.012;
    List<ScenePoint> line(double offset) => List.generate(25, (index) {
      final forward = index * 5.0;
      final bend = curve * forward * forward / 18;
      return ScenePoint(forwardMeters: forward, leftMeters: offset + bend);
    }, growable: false);

    return RoadScene(
      monotonicTimeNanos: elapsed.inMicroseconds * 1000,
      speedMps: 25.2 + math.sin(seconds * 0.8) * 0.5,
      setSpeedMps: 27.8,
      steeringAngleDegrees: curve * 720,
      engaged: true,
      gear: VehicleGear.drive,
      leftBlinker: seconds % 18 > 12 && seconds % 18 < 16,
      rightBlinker: false,
      brakeActive: seconds % 14 > 10.5 && seconds % 14 < 12.5,
      speedLimitKph: 100,
      tbt: const TbtInstruction(
        maneuver: TbtManeuver.turnLeft,
        distanceMeters: 420,
        roadName: '서울대학로 교차로',
        nextManeuver: TbtManeuver.turnRight,
        nextDistanceMeters: 1250,
        remainingDistanceMeters: 31700,
        remainingSeconds: 3600,
      ),
      plannedPath: line(0),
      leftLane: line(1.85),
      rightLane: line(-1.85),
      objects: [
        TrackedObject(
          distanceMeters: 38 + math.sin(seconds * 0.45) * 3,
          leftMeters: 0.12,
          relativeSpeedMps: -0.8,
        ),
        const TrackedObject(
          distanceMeters: 72,
          leftMeters: -3.7,
          relativeSpeedMps: 1.5,
        ),
      ],
    );
  }
}

T _enumByName<T extends Enum>(List<T> values, String? name, T fallback) {
  if (name == null) return fallback;
  return values.firstWhere(
    (value) => value.name == name,
    orElse: () => fallback,
  );
}
