import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/gpu_scene/glb_bounds.dart';
import 'package:kovalink/src/models/vehicle_model_manifest.dart';
import 'package:kovalink/src/vehicle_mesh/gltf_mesh_reader.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh_loader.dart';
import 'package:kovalink/src/features/road_view/gpu_road_surface.dart';
import 'package:kovalink/src/features/road_view/render_quality.dart';
import 'package:kovalink/src/features/road_view/road_view_screen.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_director.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_markers.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/features/road_view/scene3d/vehicle_mesh_painter.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_mesh/builtin_vehicles.dart';

RoadScene _demo(DemoRoute route, double s) => DemoDriveScenario(
  route: route,
).sceneAt(Duration(milliseconds: (s * 1000).round()));

Future<ui.Image> _render(CustomPainter painter, Size size) {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  return recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
}

Future<List<int>> _bytes(ui.Image image) async => (await image.toByteData(
  format: ui.ImageByteFormat.rawRgba,
))!.buffer.asUint8List();

void main() {
  group('render quality setting', () {
    test('defaults to automatic and round-trips through JSON', () {
      expect(const AppSettings().renderQuality, RenderQuality.auto);
      final s = const AppSettings().copyWith(
        renderQuality: RenderQuality.saver,
      );
      expect(
        AppSettings.fromJson(s.toJson()).renderQuality,
        RenderQuality.saver,
      );
      expect(
        AppSettings.fromJson({'renderQuality': 'ultra'}).renderQuality,
        RenderQuality.auto,
      );
    });

    test('policy: saver is always software, auto/high follow availability', () {
      expect(
        RenderQualityPolicy.useGpu(RenderQuality.saver, gpuAvailable: true),
        isFalse,
      );
      expect(
        RenderQualityPolicy.useGpu(RenderQuality.auto, gpuAvailable: true),
        isTrue,
      );
      expect(
        RenderQualityPolicy.useGpu(RenderQuality.high, gpuAvailable: false),
        isFalse,
      );
    });

    testWidgets('road view uses the GPU surface unless saving', (tester) async {
      final controller = GatewayController();
      GpuSurfaceRequest? last;
      Widget screen(RenderQuality q) => MaterialApp(
        home: RoadViewScreen(
          controller: controller,
          renderQuality: q,
          theme: SceneTheme.night,
          gpuSurfaceBuilder: (context, request) {
            last = request;
            return const ColoredBox(
              key: ValueKey('gpu-frame'),
              color: Colors.black,
            );
          },
        ),
      );
      await tester.pumpWidget(screen(RenderQuality.auto));
      expect(find.byKey(const ValueKey('gpu-frame')), findsOneWidget);
      expect(last!.theme, SceneTheme.night);
      expect(last!.director.camera, isNotNull);
      await tester.pumpWidget(screen(RenderQuality.saver));
      expect(find.byKey(const ValueKey('gpu-frame')), findsNothing);
      controller.dispose();
    });
  });

  group('imported packs', () {
    test('ToyCar fits by its body node; staging cloth is a prop', () {
      final glb = File('assets/vehicles/toy_car/vehicle.glb').readAsBytesSync();
      final fit = GlbBounds.vehicle(glb, body: 'ToyCar')!;
      expect(fit.props, contains('Fabric'));
      expect(fit.props, isNot(contains('Glass')));
      // Sample model is a 1e-4-scaled toy: a few centimeters long.
      expect(fit.bounds.size.z, inInclusiveRange(0.02, 0.2));
      expect(GlbBounds.of(glb)!.size.x, greaterThan(fit.bounds.size.x));
    });

    test('ToyCar glass reads as dark see-through glass in software', () async {
      final manifest = VehicleModelManifest.fromJson(
        jsonDecode(
              File('assets/vehicles/toy_car/vehicle.json').readAsStringSync(),
            )
            as Map<String, dynamic>,
      );
      final glb = File('assets/vehicles/toy_car/vehicle.glb').readAsBytesSync();
      final mesh = GltfMeshReader.read(
        glb,
        options: VehicleMeshLoader.optionsFor(manifest),
      );
      final glass = mesh.mesh.materials
          .where((m) => m.role == MeshRole.glass)
          .toList();
      expect(glass, isNotEmpty);
      for (final g in glass) {
        final c = Color(g.baseColor);
        expect(c.r + c.g + c.b, lessThan(0.6));
      }
    });
  });

  group('demo staging', () {
    test('trucks never drive beside the ego on the highway', () {
      for (final seed in [1, 7, DemoDriveScenario.defaultSeed]) {
        final s = DemoDriveScenario(route: DemoRoute.highway, seed: seed);
        for (var t = 0.0; t < 90; t += 1) {
          for (final o in s.sceneAt(Duration(seconds: t.toInt())).objects) {
            if (o.kind != TrackedObjectKind.truck) continue;
            expect(
              o.distanceMeters,
              greaterThan(40),
              reason: 'seed $seed t $t',
            );
          }
        }
      }
    });

    test('a car sits in the blind spot before each lane change', () {
      for (final (route, t) in [
        (DemoRoute.highway, 45.5),
        (DemoRoute.city, 45.5),
      ]) {
        final scene = _demo(route, t);
        final left = SceneDirector.blindSpotObject(scene, left: true);
        expect(left, isNotNull, reason: '$route');
        expect(
          SceneDirector.blindSpotObject(_demo(route, 56), left: true),
          isNull,
        );
      }
    });

    test(
      'city has pedestrians on the sidewalks and a cyclist near the turn',
      () {
        final peds = _demo(
          DemoRoute.city,
          30,
        ).objects.where((o) => o.kind == TrackedObjectKind.pedestrian);
        expect(peds, isNotEmpty);
        for (final p in peds) {
          expect(p.leftMeters.abs(), greaterThan(4.5));
        }
        expect(
          _demo(
            DemoRoute.city,
            63,
          ).objects.where((o) => o.kind == TrackedObjectKind.cyclist),
          hasLength(1),
        );
      },
    );
  });

  group('software path (절약)', () {
    const size = Size(600, 470);

    test(
      'quality features change the picture (supersampled, smooth, horizon line)',
      () async {
        final scene = _demo(DemoRoute.highway, 20);
        final on = await _bytes(
          await _render(RoadWorldPainter(scene: scene), size),
        );
        final off = await _bytes(
          await _render(
            RoadWorldPainter(scene: scene, options: SoftwareRenderOptions.off),
            size,
          ),
        );
        var diff = 0;
        for (var i = 0; i < on.length; i += 4) {
          if ((on[i] - off[i]).abs() > 6) diff++;
        }
        expect(diff, greaterThan(200));
      },
    );

    test('smooth normals are unit length and cached', () {
      final mesh = BuiltinVehicles.suvSet.lod0;
      final a = VehicleMeshPainter.smoothNormalsOf(mesh);
      expect(identical(a, VehicleMeshPainter.smoothNormalsOf(mesh)), isTrue);
      for (var i = 0; i < a.length; i += 3) {
        final l = a[i] * a[i] + a[i + 1] * a[i + 1] + a[i + 2] * a[i + 2];
        expect(l, closeTo(1, 1e-3));
      }
    });

    test('night adds headlight pools on the road ahead', () async {
      final scene = _demo(DemoRoute.highway, 20);
      final director = SceneDirector().update(scene, size);
      Future<double> brightnessAhead(SoftwareRenderOptions options) async {
        final px = await _bytes(
          await _render(
            RoadWorldPainter(
              scene: scene,
              theme: SceneTheme.night,
              director: director,
              options: options,
            ),
            size,
          ),
        );
        var sum = 0.0;
        // Road just ahead of the ego (lower middle of the frame).
        for (var y = 260; y < 300; y++) {
          for (var x = 240; x < 360; x++) {
            final i = (y * size.width.toInt() + x) * 4;
            sum += px[i] + px[i + 1] + px[i + 2];
          }
        }
        return sum;
      }

      expect(
        await brightnessAhead(const SoftwareRenderOptions()),
        greaterThan(await brightnessAhead(SoftwareRenderOptions.off) * 1.15),
      );
    });

    test('director: roll and markers do not break painting', () async {
      final scene = _demo(DemoRoute.city, 45.5);
      final frame = SceneDirector().update(scene, size);
      expect(frame.blindSpots, isNotEmpty);
      await _render(RoadWorldPainter(scene: scene, director: frame), size);
      await _render(
        SceneMarkersPainter(
          scene: scene,
          frame: frame,
          egoLength: 4.6,
          egoWidth: 1.86,
        ),
        size,
      );
      await _render(const RainOverlayPainter(timeSeconds: 3.2), size);
    });

    test('lead bubble turns from blue to red as the gap closes', () {
      final calm = SceneMarkers.bubbleColors(0).$2;
      final alarm = SceneMarkers.bubbleColors(1).$2;
      expect(calm.b, greaterThan(calm.r));
      expect(alarm.r, greaterThan(alarm.b));
    });
  });
}
