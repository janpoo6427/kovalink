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
    this.appearance = const VehicleAppearance(),
  });

  final int schemaVersion;
  final String id;
  final String displayName;
  final String asset;
  final String coordinateSystem;
  final VehicleDimensions dimensions;
  final VehicleNodeBindings nodes;
  final Map<String, VehicleCameraPreset> cameras;

  /// Optional colors used by the built-in 2D/3D-like ego renderer. Packs
  /// written before `appearance` existed keep the default palette.
  final VehicleAppearance appearance;

  /// Built-in vehicle used when no model pack can be loaded. It has no GLB
  /// asset, so only the deterministic built-in ego renderer is used.
  static const builtIn = VehicleModelManifest(
    schemaVersion: 1,
    id: 'kovalink-builtin',
    displayName: '기본 내장 차량',
    asset: '',
    coordinateSystem: 'RH_Y_UP_Z_FORWARD',
    dimensions: VehicleDimensions.reference,
    nodes: VehicleNodeBindings(),
    cameras: {},
  );

  /// GLB file names must be a single plain file inside the pack directory.
  static final RegExp _safeAssetName = RegExp(r'^[A-Za-z0-9_\-]+\.glb$');

  static bool isSafeAssetFileName(String value) =>
      _safeAssetName.hasMatch(value);

  VehicleModelManifest copyWith({
    String? asset,
    VehicleDimensions? dimensions,
  }) => VehicleModelManifest(
    schemaVersion: schemaVersion,
    id: id,
    displayName: displayName,
    asset: asset ?? this.asset,
    coordinateSystem: coordinateSystem,
    dimensions: dimensions ?? this.dimensions,
    nodes: nodes,
    cameras: cameras,
    appearance: appearance,
  );

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
      appearance: switch (json['appearance']) {
        Map<String, dynamic> value => VehicleAppearance.fromJson(value),
        _ => const VehicleAppearance(),
      },
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

  /// Mid-size passenger car. Also the size the original renderer was tuned
  /// for, so a pack with these dimensions draws exactly like before.
  static const reference = VehicleDimensions(
    length: 4.50,
    width: 1.86,
    height: 1.48,
    wheelbase: 2.75,
  );

  /// Returns null when the dimensions describe a plausible road vehicle.
  /// Values outside these bounds are treated as authoring mistakes (for
  /// example centimeters instead of meters) and replaced by [reference].
  String? get validationError {
    final values = [length, width, height, wheelbase];
    if (values.any((value) => !value.isFinite || value <= 0)) {
      return '차량 치수는 0보다 큰 숫자(m)여야 합니다.';
    }
    if (length < 2.5 || length > 7.5) return '차량 길이는 2.5–7.5 m 범위여야 합니다.';
    if (width < 1.2 || width > 2.8) return '차량 폭은 1.2–2.8 m 범위여야 합니다.';
    if (height < 0.9 || height > 3.5) return '차량 높이는 0.9–3.5 m 범위여야 합니다.';
    if (wheelbase < 1.5 || wheelbase > length - 0.3) {
      return '축간거리는 1.5 m 이상, 차량 길이보다 0.3 m 이상 짧아야 합니다.';
    }
    return null;
  }

  factory VehicleDimensions.fromJson(Map<String, dynamic> json) =>
      VehicleDimensions(
        length: (json['length'] as num).toDouble(),
        width: (json['width'] as num).toDouble(),
        height: (json['height'] as num).toDouble(),
        wheelbase: (json['wheelbase'] as num).toDouble(),
      );
}

/// ARGB colors (0xAARRGGBB) for the built-in ego renderer.
class VehicleAppearance {
  const VehicleAppearance({
    this.paintArgb = defaultPaintArgb,
    this.glassArgb = defaultGlassArgb,
    this.lampArgb = defaultLampArgb,
  });

  // Defaults reproduce the original built-in renderer palette.
  static const defaultPaintArgb = 0xFF56616D;
  static const defaultGlassArgb = 0xFF273746;
  static const defaultLampArgb = 0xFFB01D31;

  final int paintArgb;
  final int glassArgb;
  final int lampArgb;

  /// Accepts `#RRGGBB` or `#AARRGGBB`. Invalid or missing values keep the
  /// default color instead of failing the whole pack.
  factory VehicleAppearance.fromJson(Map<String, dynamic> json) =>
      VehicleAppearance(
        paintArgb: parseHexColor(json['paintColor']) ?? defaultPaintArgb,
        glassArgb: parseHexColor(json['glassColor']) ?? defaultGlassArgb,
        lampArgb: parseHexColor(json['lampColor']) ?? defaultLampArgb,
      );

  static final RegExp _hex = RegExp(r'^#?([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$');

  static int? parseHexColor(Object? value) {
    if (value is! String) return null;
    final match = _hex.firstMatch(value.trim());
    if (match == null) return null;
    final digits = match.group(1)!;
    final parsed = int.parse(digits, radix: 16);
    return digits.length == 6 ? 0xFF000000 | parsed : parsed;
  }
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
