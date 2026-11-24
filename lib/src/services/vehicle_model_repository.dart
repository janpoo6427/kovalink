import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:kovalink/src/models/ego_vehicle_profile.dart';
import 'package:kovalink/src/models/vehicle_model_manifest.dart';

/// Outcome of loading a vehicle model pack. Loading never throws: a broken
/// or missing pack falls back to the built-in model and records why.
class VehicleModelLoadResult {
  const VehicleModelLoadResult({
    required this.manifest,
    required this.glbAssetPath,
    this.warnings = const [],
  });

  /// Bundled Khronos Toy Car pack, used until the asynchronous load finishes.
  /// Same values as `assets/vehicles/toy_car/vehicle.json`, so the first
  /// frame matches the loaded state.
  static const bundledDefault = VehicleModelLoadResult(
    manifest: VehicleModelManifest(
      schemaVersion: 1,
      id: 'khronos-toy-car',
      displayName: 'Khronos Toy Car',
      asset: 'vehicle.glb',
      coordinateSystem: 'RH_Y_UP_Z_FORWARD',
      dimensions: VehicleDimensions.reference,
      nodes: VehicleNodeBindings(body: 'ToyCar'),
      cameras: {},
      appearance: VehicleAppearance(
        paintArgb: 0xFFD6DBE0,
        glassArgb: 0xFF1A222B,
      ),
      author: 'Guido Odendahl, Eric Chadwick (Khronos glTF Sample Assets)',
      license: 'CC0-1.0',
    ),
    glbAssetPath: '${VehicleModelRepository.bundledPackDirectory}vehicle.glb',
  );

  final VehicleModelManifest manifest;

  /// Flutter asset path of the GLB, or null when only the built-in renderer
  /// should be used.
  final String? glbAssetPath;
  final List<String> warnings;

  bool get usesBuiltInModel => glbAssetPath == null;

  EgoVehicleProfile get profile => EgoVehicleProfile.fromManifest(manifest);
}

class VehicleModelRepository {
  const VehicleModelRepository._();

  static const bundledPackDirectory = 'assets/vehicles/toy_car/';
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
    } on Object catch (error) {
      return _builtIn('vehicle.json을 읽을 수 없어 기본 내장 차량을 씁니다: $error');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      return _builtIn('vehicle.json 형식 오류로 기본 내장 차량을 씁니다: ${error.message}');
    }
    return resolve(decoded, directory: directory);
  }

  /// Pure manifest validation, separated from asset IO for tests.
  static VehicleModelLoadResult resolve(
    Object? decoded, {
    required String directory,
  }) {
    if (decoded is! Map<String, dynamic>) {
      return _builtIn('vehicle.json은 JSON object여야 합니다.');
    }
    VehicleModelManifest manifest;
    try {
      manifest = VehicleModelManifest.fromJson(decoded);
    } on Object catch (error) {
      return _builtIn('vehicle.json을 해석할 수 없어 기본 내장 차량을 씁니다: $error');
    }

    final warnings = <String>[];
    final dimensionError = manifest.dimensions.validationError;
    if (dimensionError != null) {
      warnings.add('$dimensionError 기본 치수를 씁니다.');
      manifest = manifest.copyWith(dimensions: VehicleDimensions.reference);
    }

    String? glbPath;
    if (manifest.coordinateSystem != supportedCoordinateSystem) {
      warnings.add(
        '지원하지 않는 좌표계 ${manifest.coordinateSystem}: GLB 대신 기본 내장 모델을 그립니다.',
      );
    } else if (!VehicleModelManifest.isSafeAssetFileName(manifest.asset)) {
      warnings.add('GLB 파일 이름이 올바르지 않아 기본 내장 모델을 그립니다.');
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
