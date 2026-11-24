import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/road_scene_painter.dart';
import 'package:kovalink/src/models/ego_vehicle_profile.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/models/vehicle_model_manifest.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';

Map<String, dynamic> _pack({
  Map<String, dynamic>? dimensions,
  String asset = 'vehicle.glb',
  String coordinateSystem = 'RH_Y_UP_Z_FORWARD',
  Map<String, dynamic>? appearance,
}) => {
  'schemaVersion': 1,
  'id': 'unit-car',
  'displayName': 'Unit Car',
  'asset': asset,
  'coordinateSystem': coordinateSystem,
  'dimensionsMeters':
      dimensions ??
      {'length': 4.8, 'width': 1.9, 'height': 1.6, 'wheelbase': 2.9},
  'appearance': ?appearance,
};

class _MissingBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      throw FlutterError('missing asset $key');
}

Future<ui.Image> _render(RoadScenePainter painter, Size size) {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  return recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
}

Future<Color> _pixel(ui.Image image, Offset at) async {
  final bytes = (await image.toByteData())!;
  final index = (at.dy.toInt() * image.width + at.dx.toInt()) * 4;
  return Color.fromARGB(
    bytes.getUint8(index + 3),
    bytes.getUint8(index),
    bytes.getUint8(index + 1),
    bytes.getUint8(index + 2),
  );
}

RoadScene _emptyScene() => const RoadScene(
  monotonicTimeNanos: 1000000000,
  speedMps: 0,
  setSpeedMps: 0,
  steeringAngleDegrees: 0,
  engaged: false,
  plannedPath: [],
  leftLane: [],
  rightLane: [],
  objects: [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('vehicle appearance', () {
    test('parses #RRGGBB and #AARRGGBB colors', () {
      expect(VehicleAppearance.parseHexColor('#C8102E'), 0xFFC8102E);
      expect(VehicleAppearance.parseHexColor('80112233'), 0x80112233);
      expect(VehicleAppearance.parseHexColor('red'), isNull);
      expect(VehicleAppearance.parseHexColor(42), isNull);
    });

    test('keeps the default palette for packs without appearance', () {
      final manifest = VehicleModelManifest.fromJson(_pack());
      expect(manifest.appearance.paintArgb, VehicleAppearance.defaultPaintArgb);
      expect(manifest.appearance.lampArgb, VehicleAppearance.defaultLampArgb);
    });

    test('invalid color falls back per field', () {
      final manifest = VehicleModelManifest.fromJson(
        _pack(appearance: {'paintColor': '#1E5AA8', 'glassColor': 'blue'}),
      );
      expect(manifest.appearance.paintArgb, 0xFF1E5AA8);
      expect(manifest.appearance.glassArgb, VehicleAppearance.defaultGlassArgb);
    });
  });

  group('model pack resolution', () {
    test('valid pack keeps its GLB inside the pack directory', () {
      final result = VehicleModelRepository.resolve(
        _pack(),
        directory: 'assets/vehicles/unit/',
      );
      expect(result.glbAssetPath, 'assets/vehicles/unit/vehicle.glb');
      expect(result.warnings, isEmpty);
      expect(result.profile.dimensions.length, 4.8);
    });

    test(
      'centimeter dimensions fall back to reference size with a warning',
      () {
        final result = VehicleModelRepository.resolve(
          _pack(
            dimensions: {
              'length': 480,
              'width': 190,
              'height': 160,
              'wheelbase': 290,
            },
          ),
          directory: 'assets/vehicles/unit/',
        );
        expect(
          result.profile.dimensions.length,
          VehicleDimensions.reference.length,
        );
        expect(result.warnings, hasLength(1));
        expect(result.glbAssetPath, isNotNull);
      },
    );

    test('wheelbase longer than the body is rejected', () {
      const dimensions = VehicleDimensions(
        length: 4.0,
        width: 1.8,
        height: 1.5,
        wheelbase: 3.9,
      );
      expect(dimensions.validationError, isNotNull);
      expect(VehicleDimensions.reference.validationError, isNull);
    });

    test('path traversal in asset name disables the GLB', () {
      for (final asset in [
        '../secret.glb',
        'sub/vehicle.glb',
        'vehicle.gltf',
      ]) {
        final result = VehicleModelRepository.resolve(
          _pack(asset: asset),
          directory: 'assets/vehicles/unit/',
        );
        expect(result.glbAssetPath, isNull, reason: asset);
        expect(result.usesBuiltInModel, isTrue);
        expect(result.warnings, isNotEmpty);
      }
    });

    test('unsupported coordinate system uses the built-in renderer', () {
      final result = VehicleModelRepository.resolve(
        _pack(coordinateSystem: 'LH_Z_UP'),
        directory: 'assets/vehicles/unit/',
      );
      expect(result.glbAssetPath, isNull);
      expect(result.manifest.id, 'unit-car');
    });

    test('broken manifest falls back to the built-in vehicle', () {
      for (final decoded in <Object?>[
        null,
        <Object>[],
        {'schemaVersion': 2},
        {'schemaVersion': 1, 'id': 'no-dimensions'},
      ]) {
        final result = VehicleModelRepository.resolve(
          decoded,
          directory: 'assets/vehicles/unit/',
        );
        expect(result.manifest.id, VehicleModelManifest.builtIn.id);
        expect(result.usesBuiltInModel, isTrue);
        expect(result.warnings, hasLength(1));
      }
    });

    test(
      'bundled toy car pack loads and matches the first-frame default',
      () async {
        final result = await VehicleModelRepository.loadBundled();
        const initial = VehicleModelLoadResult.bundledDefault;
        expect(result.warnings, isEmpty);
        expect(result.glbAssetPath, initial.glbAssetPath);
        expect(result.manifest.id, initial.manifest.id);
        expect(result.profile, initial.profile);
      },
    );

    test('missing pack asset falls back without throwing', () async {
      final result = await VehicleModelRepository.loadBundled(
        bundle: _MissingBundle(),
      );
      expect(result.usesBuiltInModel, isTrue);
      expect(result.warnings.single, contains('vehicle.json'));
    });
  });

  group('ego vehicle profile', () {
    test('reference car keeps the original renderer proportions', () {
      const profile = EgoVehicleProfile.builtIn;
      expect(profile.chaseWidthScale, closeTo(1, 1e-9));
      expect(profile.chaseHeightRatio, closeTo(0.58, 1e-9));
      final rect = RoadScenePainter.chaseEgoBodyRect(
        const Size(400, 800),
        profile,
      );
      expect(rect.width, closeTo(152, 1e-9));
      expect(rect.height, closeTo(152 * 0.58, 1e-9));
    });

    test('manifest size changes the drawn ego and is clamped', () {
      VehicleModelManifest manifest(double width, double height) =>
          VehicleModelManifest.fromJson(
            _pack(
              dimensions: {
                'length': 5.2,
                'width': width,
                'height': height,
                'wheelbase': 3.1,
              },
            ),
          );
      final wide = EgoVehicleProfile.fromManifest(manifest(2.1, 1.9));
      final narrow = EgoVehicleProfile.fromManifest(manifest(1.3, 1.0));
      const size = Size(400, 800);
      final reference = RoadScenePainter.chaseEgoBodyRect(
        size,
        EgoVehicleProfile.builtIn,
      );
      expect(
        RoadScenePainter.chaseEgoBodyRect(size, wide).width,
        greaterThan(reference.width),
      );
      expect(
        RoadScenePainter.chaseEgoBodyRect(size, narrow).width,
        lessThan(reference.width),
      );
      expect(wide.chaseHeightRatio, greaterThan(0.58));
      expect(narrow.chaseWidthScale, greaterThanOrEqualTo(0.75));
    });

    test('top-down geometry places the body behind the front bumper', () {
      const profile = EgoVehicleProfile.builtIn;
      expect(profile.rearBumperForwardMeters, -4.5);
      expect(profile.frontAxleForwardMeters, closeTo(-0.875, 1e-9));
      expect(profile.rearAxleForwardMeters, closeTo(-3.625, 1e-9));
    });

    test('manifest paint color reaches the rendered ego body', () async {
      Future<Color> bodyPixel(int paintArgb) async {
        final profile = EgoVehicleProfile(
          displayName: 'color',
          dimensions: VehicleDimensions.reference,
          appearance: VehicleAppearance(paintArgb: paintArgb),
        );
        const size = Size(400, 600);
        final image = await _render(
          RoadScenePainter(
            _emptyScene(),
            drawEgoVehicle: true,
            vehicle: profile,
          ),
          size,
        );
        final rect = RoadScenePainter.chaseEgoBodyRect(size, profile);
        return _pixel(image, rect.center.translate(0, rect.height * 0.17));
      }

      final red = await bodyPixel(0xFFC8102E);
      final blue = await bodyPixel(0xFF1E5AA8);
      expect((red.r * 255) - (red.b * 255), greaterThan(60));
      expect((blue.b * 255) - (blue.r * 255), greaterThan(60));
    });
  });
}
