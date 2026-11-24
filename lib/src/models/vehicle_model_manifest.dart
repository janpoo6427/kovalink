class VehicleModelManifest {
  const VehicleModelManifest({
    required this.schemaVersion,
    required this.id,
    required this.displayName,
    required this.asset,
    required this.coordinateSystem,
    required this.dimensions,
    required this.nodes,
    required this.cameras,
  });

  final int schemaVersion;
  final String id;
  final String displayName;
  final String asset;
  final String coordinateSystem;
  final VehicleDimensions dimensions;
  final VehicleNodeBindings nodes;
  final Map<String, VehicleCameraPreset> cameras;

  factory VehicleModelManifest.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported vehicle model schemaVersion');
    }
    return VehicleModelManifest(
      schemaVersion: 1,
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      asset: json['asset'] as String,
      coordinateSystem: json['coordinateSystem'] as String,
      dimensions: VehicleDimensions.fromJson(
        json['dimensionsMeters'] as Map<String, dynamic>,
      ),
      nodes: VehicleNodeBindings.fromJson(
        json['nodes'] as Map<String, dynamic>? ?? const {},
      ),
      cameras: (json['cameras'] as Map<String, dynamic>? ?? const {}).map(
        (key, value) => MapEntry(
          key,
          VehicleCameraPreset.fromJson(value as Map<String, dynamic>),
        ),
      ),
    );
  }
}

class VehicleDimensions {
  const VehicleDimensions({
    required this.length,
    required this.width,
    required this.height,
    required this.wheelbase,
  });

  final double length;
  final double width;
  final double height;
  final double wheelbase;

  factory VehicleDimensions.fromJson(Map<String, dynamic> json) =>
      VehicleDimensions(
        length: (json['length'] as num).toDouble(),
        width: (json['width'] as num).toDouble(),
        height: (json['height'] as num).toDouble(),
        wheelbase: (json['wheelbase'] as num).toDouble(),
      );
}

class VehicleNodeBindings {
  const VehicleNodeBindings({
    this.body,
    this.frontLeftWheel,
    this.frontRightWheel,
    this.steeringWheel,
    this.leftTurnSignals = const [],
    this.rightTurnSignals = const [],
    this.brakeLights = const [],
    this.reverseLights = const [],
  });

  final String? body;
  final String? frontLeftWheel;
  final String? frontRightWheel;
  final String? steeringWheel;
  final List<String> leftTurnSignals;
  final List<String> rightTurnSignals;
  final List<String> brakeLights;
  final List<String> reverseLights;

  factory VehicleNodeBindings.fromJson(Map<String, dynamic> json) {
    List<String> names(String key) =>
        (json[key] as List<dynamic>? ?? const []).cast<String>();
    return VehicleNodeBindings(
      body: json['body'] as String?,
      frontLeftWheel: json['frontLeftWheel'] as String?,
      frontRightWheel: json['frontRightWheel'] as String?,
      steeringWheel: json['steeringWheel'] as String?,
      leftTurnSignals: names('leftTurnSignals'),
      rightTurnSignals: names('rightTurnSignals'),
      brakeLights: names('brakeLights'),
      reverseLights: names('reverseLights'),
    );
  }
}

class VehicleCameraPreset {
  const VehicleCameraPreset({required this.position, required this.target});

  final List<double> position;
  final List<double> target;

  factory VehicleCameraPreset.fromJson(Map<String, dynamic> json) =>
      VehicleCameraPreset(
        position: _vector(json['position']),
        target: _vector(json['target']),
      );

  static List<double> _vector(Object? value) {
    final result = (value as List<dynamic>)
        .map((item) => (item as num).toDouble())
        .toList(growable: false);
    if (result.length != 3) {
      throw const FormatException('Camera vectors must contain three values');
    }
    return result;
  }
}
