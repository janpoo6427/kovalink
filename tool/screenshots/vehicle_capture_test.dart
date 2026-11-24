// Imported vehicle example for review: packs the bundled Khronos ToyCar
// (CC0) as a user .kovamodel under a new id, imports it through the same
// validator/library the app uses, loads its GLB through VehicleMeshLoader
// and captures the home screen with it as the ego.
//
//   KOVA_SHOT_DIR=/path flutter test tool/screenshots/vehicle_capture_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kovalink_home.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh_loader.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';
import 'package:kovalink/src/vehicle_pack/zip_writer.dart';

import 'shot_support.dart';

void main() {
  for (final (name, size, route, seconds, theme) in const [
    (
      'app_import_toycar_highway_1200x945',
      Size(1200, 945),
      DemoRoute.highway,
      75.0,
      SceneTheme.clear,
    ),
    (
      'app_import_toycar_city_1081x1200',
      Size(1081, 1200),
      DemoRoute.city,
      85.0,
      SceneTheme.overcast,
    ),
  ]) {
    testWidgets('capture $name', (tester) async {
      await tester.runAsync(loadReviewFonts);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('kl_import_'),
      );
      final library = VehicleModelLibrary(storageRoot: () async => root!);
      final model = await tester.runAsync(() async {
        const dir = 'assets/vehicles/toy_car';
        final manifest =
            jsonDecode(File('$dir/vehicle.json').readAsStringSync())
                as Map<String, dynamic>;
        manifest['id'] = 'toy-car-import';
        manifest['displayName'] = 'Toy Car (가져온 팩)';
        final archive = ZipWriter.build([
          ZipWriterEntry('vehicle.json', utf8.encode(jsonEncode(manifest))),
          ZipWriterEntry(
            'vehicle.glb',
            File('$dir/vehicle.glb').readAsBytesSync(),
          ),
          ZipWriterEntry(
            'LICENSE.md',
            File('$dir/LICENSE.md').readAsBytesSync(),
          ),
        ]);
        final outcome = await library.importPack(archive);
        expect(outcome.imported, isTrue, reason: '${outcome.rejection}');
        final loaded = await library.load('toy-car-import');
        expect(loaded.glbAssetPath, startsWith('file://'));
        final mesh = await VehicleMeshLoader.load(
          loaded.glbAssetPath,
          loaded.manifest,
        );
        expect(mesh.mesh, isNotNull, reason: mesh.warnings.join('\n'));
        // ignore: avoid_print
        print(
          'KOVA_IMPORT ${loaded.manifest.id}: '
          'lod0 ${mesh.mesh!.lod0.triangleCount} / lod1 '
          '${mesh.mesh!.lod1.triangleCount} / lod2 '
          '${mesh.mesh!.lod2.triangleCount} triangles; '
          '${mesh.warnings.join(' | ')}',
        );
        return loaded.withMesh(mesh.mesh, mesh.warnings);
      });
      final controller = GatewayController();
      controller.scene = DemoDriveScenario(
        route: route,
      ).sceneAt(Duration(milliseconds: (seconds * 1000).round()));
      final settings = SettingsController(
        store: MemorySettingsStore(),
        initial: AppSettings(
          viewpoint: SceneViewpoint.chase,
          sceneTheme: theme,
          demoRoute: route,
          vehicleModelId: 'toy-car-import',
        ),
      );
      final vehicleModel = ValueNotifier<VehicleModelLoadResult>(model!);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'Roboto', useMaterial3: true),
          home: RepaintBoundary(
            key: key,
            child: KovaLinkHome(
              controller: controller,
              vehicleModel: vehicleModel,
              settings: settings,
              library: library,
            ),
          ),
        ),
      );
      await tester.pump();
      await saveBoundary(tester, key, name);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      vehicleModel.dispose();
      await tester.runAsync(() => root!.delete(recursive: true));
    });
  }
}
