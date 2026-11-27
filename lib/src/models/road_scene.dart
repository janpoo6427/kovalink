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

enum TrackedObjectKind {
  vehicle,
  pedestrian,
  unknown,
  truck,
  cyclist,
  trafficCone,
}

/// Road context reported by the gateway (map/navigation derived). Drives
/// display choices only, such as roadside scenery.
enum RoadType { highway, city, unknown }

enum LaneLineColor { white, yellow, blue, unknown }

enum LaneLineStyle { solid, dashed, doubleSolid, unknown }

/// One painted lane line in the vehicle frame (`x` forward, `y` left, m).
class LaneLine {
  const LaneLine({
    required this.points,
    this.probability = 1,
    this.color = LaneLineColor.white,
    this.style = LaneLineStyle.solid,
  });

  final List<ScenePoint> points;

  /// Model confidence 0..1. The renderer fades low-confidence lines.
  final double probability;
  final LaneLineColor color;
  final LaneLineStyle style;

  factory LaneLine.fromJson(Map<String, dynamic> json) => LaneLine(
    points: _pointList(json['points']),
    probability: ((json['probability'] as num?) ?? 1).toDouble().clamp(
      0.0,
      1.0,
    ),
    color: _enumByName(
      LaneLineColor.values,
      json['color'] as String?,
      LaneLineColor.unknown,
    ),
    style: _enumByName(
      LaneLineStyle.values,
      json['style'] as String?,
      LaneLineStyle.unknown,
    ),
  );
}

List<ScenePoint> _pointList(Object? value) =>
    (value as List<dynamic>? ?? const [])
        .map((item) => ScenePoint.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);

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
    this.mainText,
  });

  final TbtManeuver maneuver;

  /// Guidance text of the navigation app (e.g. a junction name), if any.
  final String? mainText;
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
    mainText: json['mainText'] as String?,
  );
}

/// Which navigation app feeds kovapilot (gateway `navigation`).
enum NavigationSource { carrotV2, carrotLegacy, none }

class NavigationLink {
  const NavigationLink({
    required this.source,
    this.appVersion,
    this.lastReceivedAgeMs,
    this.guidanceActive = false,
    this.offRoute = false,
  });

  final NavigationSource source;
  final String? appVersion;
  final int? lastReceivedAgeMs;
  final bool guidanceActive;
  final bool offRoute;

  factory NavigationLink.fromJson(Map<String, dynamic> json) => NavigationLink(
    source: _enumByName(
      NavigationSource.values,
      json['source'] as String?,
      NavigationSource.none,
    ),
    appVersion: json['appVersion'] as String?,
    lastReceivedAgeMs: (json['lastReceivedAgeMs'] as num?)?.toInt(),
    guidanceActive: json['guidanceActive'] as bool? ?? false,
    offRoute: json['offRoute'] as bool? ?? false,
  );
}

enum AutoLaneChangeSetting { on, off, unknown }

/// modelV2 lane change state as the gateway names it.
enum LaneChangePhase {
  off,
  preLaneChange,
  laneChangeStarting,
  laneChangeFinishing,
  unknown,
}

/// kovapilot automatic lane change (modelV2.meta.kovaAutoLaneChange).
enum AutoLaneChangeAuto { none, pending, waiting, returning, unknown }

enum LaneChangeSide { left, right }

/// Automatic lane change state (gateway `autoLaneChange`, display only).
/// Values the build does not report stay unknown / null.
class AutoLaneChangeStatus {
  const AutoLaneChangeStatus({
    this.setting = AutoLaneChangeSetting.unknown,
    this.phase = LaneChangePhase.unknown,
    this.direction,
    this.auto = AutoLaneChangeAuto.unknown,
    this.blindSpotLeft,
    this.blindSpotRight,
    this.blindSpotFresh,
  });

  final AutoLaneChangeSetting setting;
  final LaneChangePhase phase;

  /// Null without a lane change.
  final LaneChangeSide? direction;
  final AutoLaneChangeAuto auto;
  final bool? blindSpotLeft;
  final bool? blindSpotRight;
  final bool? blindSpotFresh;

  factory AutoLaneChangeStatus.fromJson(Map<String, dynamic> json) =>
      AutoLaneChangeStatus(
        setting: _enumByName(
          AutoLaneChangeSetting.values,
          json['setting'] as String?,
          AutoLaneChangeSetting.unknown,
        ),
        phase: _enumByName(
          LaneChangePhase.values,
          json['laneChange'] as String?,
          LaneChangePhase.unknown,
        ),
        direction: switch (json['direction']) {
          String name =>
            LaneChangeSide.values
                .where((side) => side.name == name)
                .firstOrNull,
          _ => null,
        },
        auto: _enumByName(
          AutoLaneChangeAuto.values,
          json['auto'] as String?,
          AutoLaneChangeAuto.unknown,
        ),
        blindSpotLeft: json['blindSpotLeft'] as bool?,
        blindSpotRight: json['blindSpotRight'] as bool?,
        blindSpotFresh: json['blindSpotFresh'] as bool?,
      );
}

class TrackedObject {
  const TrackedObject({
    required this.distanceMeters,
    required this.leftMeters,
    required this.relativeSpeedMps,
    this.kind = TrackedObjectKind.vehicle,
    this.id,
    this.lengthMeters,
    this.widthMeters,
    this.heightMeters,
    this.isLead = false,
    this.brakeLights = false,
  });

  /// Gap from the ego front bumper to the object's rear, meters.
  final double distanceMeters;
  final double leftMeters;
  final double relativeSpeedMps;
  final TrackedObjectKind kind;
  final int? id;
  final double? lengthMeters;
  final double? widthMeters;
  final double? heightMeters;

  /// True when the planner/radar marks this object as the lead.
  final bool isLead;
  final bool brakeLights;

  /// Box size used for drawing. Reported sizes win; otherwise a typical
  /// size for the kind.
  double get length => lengthMeters ?? _defaultSize.$1;
  double get width => widthMeters ?? _defaultSize.$2;
  double get height => heightMeters ?? _defaultSize.$3;

  (double, double, double) get _defaultSize => switch (kind) {
    TrackedObjectKind.vehicle => (4.6, 1.85, 1.45),
    TrackedObjectKind.truck => (9.0, 2.5, 3.2),
    TrackedObjectKind.pedestrian => (0.5, 0.5, 1.7),
    TrackedObjectKind.cyclist => (1.8, 0.6, 1.7),
    TrackedObjectKind.trafficCone => (0.4, 0.4, 0.7),
    TrackedObjectKind.unknown => (1.0, 1.0, 1.0),
  };

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
      id: (json['id'] as num?)?.toInt(),
      lengthMeters: _positive(json['lengthMeters']),
      widthMeters: _positive(json['widthMeters']),
      heightMeters: _positive(json['heightMeters']),
      isLead: json['isLead'] as bool? ?? false,
      brakeLights: json['brakeLights'] as bool? ?? false,
    );
  }
}

double? _positive(Object? value) {
  final number = (value as num?)?.toDouble();
  return number != null && number.isFinite && number > 0 ? number : null;
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
    List<LaneLine>? laneLines,
    this.roadEdges = const [],
    this.roadType = RoadType.unknown,
    this.odometerMeters = 0,
    this.roadName,
    this.trafficSignal,
    this.roadAlerts = const [],
    this.laneGuidance = const [],
    this.navigation,
    this.autoLaneChange,
    // Kept private so callers read [laneLines], which applies the fallback.
    // ignore: prefer_initializing_formals
  }) : _laneLines = laneLines;

  final int monotonicTimeNanos;

  /// Current road name from navigation (display only).
  final String? roadName;
  final TrafficSignal? trafficSignal;

  /// Upcoming enforcement/toll points, nearest first.
  final List<RoadAlert> roadAlerts;

  /// Lanes at the next maneuver, left to right.
  final List<LaneGuide> laneGuidance;

  /// The navigation app kovapilot receives (null: the gateway sent none,
  /// e.g. the demo). Turn-by-turn is drawn only from a connected app.
  final NavigationLink? navigation;
  final AutoLaneChangeStatus? autoLaneChange;
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
  final List<LaneLine>? _laneLines;

  /// Road boundaries (curbs/barriers), outermost first-left then right.
  final List<List<ScenePoint>> roadEdges;
  final RoadType roadType;

  /// Distance driven, used only to scroll dashes and scenery smoothly.
  final double odometerMeters;

  /// Typed lane lines. Frames without `laneLines` fall back to the legacy
  /// `leftLane`/`rightLane` pair as solid white, full-confidence lines.
  List<LaneLine> get laneLines =>
      _laneLines ??
      [
        if (leftLane.length >= 2) LaneLine(points: leftLane),
        if (rightLane.length >= 2) LaneLine(points: rightLane),
      ];

  /// The lead object: explicitly marked by the gateway, else the nearest
  /// vehicle-like object within the ego corridor along the planned path.
  TrackedObject? get leadObject {
    for (final object in objects) {
      if (object.isLead) return object;
    }
    TrackedObject? best;
    for (final object in objects) {
      if (object.distanceMeters <= 0) continue;
      if (object.kind != TrackedObjectKind.vehicle &&
          object.kind != TrackedObjectKind.truck) {
        continue;
      }
      final center = pathLeftAt(object.distanceMeters);
      if ((object.leftMeters - center).abs() > 1.5) continue;
      if (best == null || object.distanceMeters < best.distanceMeters) {
        best = object;
      }
    }
    return best;
  }

  /// Lateral offset of the planned path at [forward] meters (0 if absent).
  double pathLeftAt(double forward) =>
      plannedPath.length < 2 ? 0 : interpolateLeft(plannedPath, forward);

  /// Linear interpolation of `leftMeters` at [forward]; extrapolates with
  /// the first/last segment so the road extends behind and beyond samples.
  static double interpolateLeft(List<ScenePoint> points, double forward) {
    if (points.isEmpty) return 0;
    if (points.length == 1) return points.first.leftMeters;
    var index = 0;
    while (index < points.length - 2 &&
        points[index + 1].forwardMeters < forward) {
      index++;
    }
    final a = points[index];
    final b = points[index + 1];
    final span = b.forwardMeters - a.forwardMeters;
    if (span.abs() < 1e-9) return a.leftMeters;
    final t = (forward - a.forwardMeters) / span;
    return a.leftMeters + (b.leftMeters - a.leftMeters) * t;
  }

  double get speedKph => speedMps * 3.6;

  /// Standby frame shown when neither the demo nor a gateway is active:
  /// empty road, unknown gear, nothing invented.
  static const idle = RoadScene(
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
      laneLines: switch (json['laneLines']) {
        List<dynamic> value =>
          value
              .map((item) => LaneLine.fromJson(item as Map<String, dynamic>))
              .toList(growable: false),
        _ => null,
      },
      roadEdges: (json['roadEdges'] as List<dynamic>? ?? const [])
          .map(_pointList)
          .toList(growable: false),
      roadType: _enumByName(
        RoadType.values,
        json['roadType'] as String?,
        RoadType.unknown,
      ),
      odometerMeters: (json['odometerMeters'] as num? ?? 0).toDouble(),
      roadName: json['roadName'] as String?,
      trafficSignal: switch (json['trafficSignal']) {
        Map<String, dynamic> value => TrafficSignal.fromJson(value),
        _ => null,
      },
      roadAlerts: (json['roadAlerts'] as List<dynamic>? ?? const [])
          .map((item) => RoadAlert.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      laneGuidance: (json['laneGuidance'] as List<dynamic>? ?? const [])
          .map((item) => LaneGuide.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      navigation: switch (json['navigation']) {
        Map<String, dynamic> value => NavigationLink.fromJson(value),
        _ => null,
      },
      autoLaneChange: switch (json['autoLaneChange']) {
        Map<String, dynamic> value => AutoLaneChangeStatus.fromJson(value),
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

enum TrafficSignalState { red, yellow, green, unknown }

/// Next traffic signal on the route (navigation-derived, display only).
class TrafficSignal {
  const TrafficSignal({
    required this.state,
    this.leftArrow = false,
    this.remainingSeconds,
    this.distanceMeters,
  });

  final TrafficSignalState state;

  /// Protected left-turn arrow lit.
  final bool leftArrow;
  final int? remainingSeconds;
  final double? distanceMeters;

  factory TrafficSignal.fromJson(Map<String, dynamic> json) => TrafficSignal(
    state: _enumByName(
      TrafficSignalState.values,
      json['state'] as String?,
      TrafficSignalState.unknown,
    ),
    leftArrow: json['leftArrow'] as bool? ?? false,
    remainingSeconds: (json['remainingSeconds'] as num?)?.toInt(),
    distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
  );
}

enum RoadAlertKind { speedCamera, sectionCamera, tollgate, schoolZone, unknown }

class RoadAlert {
  const RoadAlert({
    required this.kind,
    required this.distanceMeters,
    this.speedLimitKph,
  });

  final RoadAlertKind kind;
  final double distanceMeters;
  final double? speedLimitKph;

  factory RoadAlert.fromJson(Map<String, dynamic> json) => RoadAlert(
    kind: _enumByName(
      RoadAlertKind.values,
      json['kind'] as String?,
      RoadAlertKind.unknown,
    ),
    distanceMeters: (json['distanceMeters'] as num).toDouble(),
    speedLimitKph: (json['speedLimitKph'] as num?)?.toDouble(),
  );
}

enum LaneDirection { straight, left, right, uTurn }

class LaneGuide {
  const LaneGuide({required this.directions, this.recommended = false});

  final List<LaneDirection> directions;
  final bool recommended;

  factory LaneGuide.fromJson(Map<String, dynamic> json) => LaneGuide(
    directions: (json['directions'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .map(
          (name) => LaneDirection.values.firstWhere(
            (value) => value.name == name,
            orElse: () => LaneDirection.straight,
          ),
        )
        .toList(growable: false),
    recommended: json['recommended'] as bool? ?? false,
  );
}
