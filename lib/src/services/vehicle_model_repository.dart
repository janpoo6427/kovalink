import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:kovalink/src/models/ego_vehicle_profile.dart';
import 'package:kovalink/src/models/vehicle_model_manifest.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh.dart';

/// Outcome of loading a vehicle model pack. Loading never throws: a broken
/// or missing pack falls back to the built-in model and records why.
class VehicleModelLoadResult {
  const VehicleModelLoadResult({
    required this.manifest,
    required this.glbAssetPath,
    this.warnings = const [],
    this.mesh,
  });

  /// Bundled KovaLink SUV pack, used until the asynchronous load finishes.
  /// Same values as `assets/vehicles/kovalink_basic/vehicle.json`, so the
  /// first frame matches the loaded state (the renderer draws the same
  /// built-in SUV mesh until the GLB levels arrive).
  static const bundledDefault = VehicleModelLoadResult(
    manifest: VehicleModelManifest(
      schemaVersion: 1,
      id: 'kovalink-basic',
      displayName: 'KovaLink 기본 SUV',
      asset: 'vehicle.glb',
      coordinateSystem: 'RH_Y_UP_Z_FORWARD',
      dimensions: VehicleDimensions(
        length: 4.60,
        width: 1.86,
        height: 1.69,
        wheelbase: 2.80,
      ),
      nodes: VehicleNodeBindings(body: 'Body'),
      cameras: {},
      appearance: VehicleAppearance(
        paintArgb: 0xFFE6E9EC,
        glassArgb: 0xFF141B23,
        lampArgb: 0xFFA0172A,
      ),
      author: 'KovaLink project',
      license: 'CC0-1.0',
    ),
    glbAssetPath: '${VehicleModelRepository.bundledPackDirectory}vehicle.glb',
  );

  final VehicleModelManifest manifest;

  /// Flutter asset path of the GLB, or null when only the built-in renderer
  /// should be used.
  final String? glbAssetPath;
  final List<String> warnings;

  /// Render levels read from the GLB for the in-app road renderer, or null
  /// while loading / when the GLB cannot be drawn (built-in SUV then).
  final VehicleMeshSet? mesh;

  bool get usesBuiltInModel => glbAssetPath == null;

  VehicleModelLoadResult withMesh(
    VehicleMeshSet? mesh, [
    List<String> extraWarnings = const [],
  ]) => VehicleModelLoadResult(
    manifest: manifest,
    glbAssetPath: glbAssetPath,
    warnings: List.unmodifiable([...warnings, ...extraWarnings]),
    mesh: mesh,
  );

  EgoVehicleProfile get profile => EgoVehicleProfile.fromManifest(manifest);
}

class VehicleModelRepository {
  const VehicleModelRepository._();

  static const bundledPackDirectory = 'assets/vehicles/kovalink_basic/';
  static const supportedCoordinateSystem = 'RH_Y_UP_Z_FORWARD';

  static Future<VehicleModelLoadResult> loadBundled({
    AssetBundle? bundle,
    String directory = bundledPackDirectory,
  }) async {
    final String text;
    try {
      text = await (bundle ?? rootBundle).loadString(
        '${directory}vehicle.json',
      );
    } on Object {
      return _builtIn('vehicle.json을 읽을 수 없어 기본 차량을 써요.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return _builtIn('vehicle.json 형식이 잘못돼 기본 차량을 써요.');
    }
    return resolve(decoded, directory: directory);
  }

  /// Pure manifest validation, separated from asset IO for tests.
  static VehicleModelLoadResult resolve(
    Object? decoded, {
    required String directory,
  }) {
    if (decoded is! Map<String, dynamic>) {
      return _builtIn('vehicle.json은 JSON 객체여야 해요.');
    }
    VehicleModelManifest manifest;
    try {
      manifest = VehicleModelManifest.fromJson(decoded);
    } on Object {
      return _builtIn('vehicle.json을 읽을 수 없어 기본 차량을 써요.');
    }

    final warnings = <String>[];
    final dimensionError = manifest.dimensions.validationError;
    if (dimensionError != null) {
      warnings.add('$dimensionError 기본 치수를 써요.');
      manifest = manifest.copyWith(dimensions: VehicleDimensions.reference);
    }

    String? glbPath;
    if (manifest.coordinateSystem != supportedCoordinateSystem) {
      warnings.add('쓸 수 없는 좌표계라 기본 모델로 그려요: ${manifest.coordinateSystem}');
    } else if (!VehicleModelManifest.isSafeAssetFileName(manifest.asset)) {
      warnings.add('GLB 파일 이름이 잘못돼 기본 모델로 그려요.');
    } else {
      glbPath = '$directory${manifest.asset}';
    }
    return VehicleModelLoadResult(
      manifest: manifest,
      glbAssetPath: glbPath,
      warnings: List.unmodifiable(warnings),
    );
  }

  static VehicleModelLoadResult _builtIn(String warning) =>
      VehicleModelLoadResult(
        manifest: VehicleModelManifest.builtIn,
        glbAssetPath: null,
        warnings: [warning],
      );
}
