import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/features/road_view/road_view_screen.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/models/display_units.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';
import 'package:kovalink/src/vehicle_pack/zip_writer.dart';

/// Valid pack built from the bundled CC0 example GLB.
Uint8List _validPack({String id = 'my-import-car'}) => ZipWriter.build([
  ZipWriterEntry(
    'vehicle.json',
    utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'id': id,
        'displayName': '가져온 차',
        'author': 'Tester',
        'license': 'CC0-1.0',
        'asset': 'vehicle.glb',
        'coordinateSystem': 'RH_Y_UP_Z_FORWARD',
        'dimensionsMeters': {
          'length': 4.9,
          'width': 1.95,
          'height': 1.7,
          'wheelbase': 2.9,
        },
        'appearance': {'paintColor': '#C8102E'},
      }),
    ),
  ),
  ZipWriterEntry(
    'vehicle.glb',
    File('assets/vehicles/kovalink_basic/vehicle.glb').readAsBytesSync(),
  ),
  ZipWriterEntry('LICENSE.md', utf8.encode('CC0-1.0')),
]);

Uint8List _traversalPack() => ZipWriter.build([
  ZipWriterEntry('vehicle.json', utf8.encode('{}')),
  const ZipWriterEntry('../evil.sh', [0x23, 0x21]),
]);

/// Lets real file IO started from widgets finish (IO completes only in the
/// real event loop; continuations then run on the next pump).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
  }
}

void main() {
  group('app settings model', () {
    test('round-trips through JSON', () {
      const settings = AppSettings(
        speedUnit: SpeedUnit.mph,
        viewpoint: SceneViewpoint.driver,
        sceneTheme: SceneTheme.overcast,
        appTheme: AppThemeMode.light,
        brightness: 0.6,
        showLanes: false,
        showHud: false,
        demoMode: false,
        demoRoute: DemoRoute.highway,
        telemetryEndpoint: 'ws://192.168.0.10:8082/v1/telemetry',
        vehicleModelId: 'my-car',
        nativeVehicleOverlay: true,
      );
      final restored = AppSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
      );
      expect(restored, settings);
      expect(restored.layers.lanes, isFalse);
      expect(restored.layers.objects, isTrue);
    });

    test('invalid stored fields fall back individually', () {
      final settings = AppSettings.fromJson({
        'speedUnit': 'furlongs',
        'viewpoint': 'topDown',
        'brightness': 7,
        'showPath': 'yes',
        'telemetryEndpoint': 'ws://example.com/v1/telemetry',
        'signalingEndpoint': 'https://fdroid.org/stream',
        'vehicleModelId': '../etc',
      });
      expect(settings.speedUnit, SpeedUnit.kph);
      expect(settings.viewpoint, SceneViewpoint.topDown);
      expect(settings.brightness, 1.0);
      expect(settings.showPath, isTrue);
      expect(settings.telemetryEndpoint, AppSettings.defaultTelemetryEndpoint);
      expect(settings.signalingEndpoint, AppSettings.defaultSignalingEndpoint);
      expect(settings.vehicleModelId, isNull);
      expect(
        AppSettings.fromJson({'brightness': 0.1}).brightness,
        AppSettings.minBrightness,
      );
    });

    test('exposes no vehicle-control or developer switches', () {
      final keys = const AppSettings().toJson().keys.map(
        (k) => k.toLowerCase(),
      );
      for (final forbidden in [
        'steer',
        'accel',
        'brake',
        'engage',
        'param',
        'longitudinal',
        'staging',
        'canfd',
      ]) {
        expect(
          keys.where((k) => k.contains(forbidden)),
          isEmpty,
          reason: forbidden,
        );
      }
    });
  });

  group('settings persistence', () {
    late Directory root;
    setUp(
      () async =>
          root = await Directory.systemTemp.createTemp('kovalink_settings_'),
    );
    tearDown(() async => root.delete(recursive: true));

    test('survives an app restart via the settings file', () async {
      final first = SettingsController(
        store: FileSettingsStore(() async => root),
      );
      await first.load();
      await first.update(
        (s) => s.copyWith(
          viewpoint: SceneViewpoint.topDown,
          speedUnit: SpeedUnit.mph,
        ),
      );
      expect(
        first.setTelemetryEndpoint('ws://10.0.0.7:8082/v1/telemetry'),
        isNull,
      );
      await first.update((s) => s);
      expect(
        File('${root.path}/${FileSettingsStore.fileName}.tmp').existsSync(),
        isFalse,
      );

      final second = SettingsController(
        store: FileSettingsStore(() async => root),
      );
      await second.load();
      expect(second.value.viewpoint, SceneViewpoint.topDown);
      expect(second.value.speedUnit, SpeedUnit.mph);
      expect(second.value.telemetryEndpoint, 'ws://10.0.0.7:8082/v1/telemetry');
    });

    test('corrupt file keeps defaults and reports the problem', () async {
      File(
        '${root.path}/${FileSettingsStore.fileName}',
      ).writeAsStringSync('{not json');
      final controller = SettingsController(
        store: FileSettingsStore(() async => root),
      );
      await controller.load();
      expect(controller.value, const AppSettings());
      expect(controller.storageError, isNotNull);
    });

    test('endpoint setters apply the local-only policy', () async {
      final store = MemorySettingsStore();
      final controller = SettingsController(store: store);
      final error = controller.setTelemetryEndpoint(
        'ws://example.com/v1/telemetry',
      );
      expect(error, contains('같은 네트워크'));
      expect(
        controller.value.telemetryEndpoint,
        AppSettings.defaultTelemetryEndpoint,
      );
      expect(controller.setSignalingEndpoint('ftp://comma.local/x'), isNotNull);
      expect(
        controller.setSignalingEndpoint('http://192.168.1.5:8082/v1/stream'),
        isNull,
      );
      await controller.update((s) => s);
      expect(store.writes, 1);
    });
  });

  group('settings screen', () {
    late Directory root;
    late GatewayController gateway;
    late SettingsController settings;
    late VehicleModelLibrary library;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kovalink_screen_');
      gateway = GatewayController();
      settings = SettingsController(store: MemorySettingsStore());
      library = VehicleModelLibrary(storageRoot: () async => root);
    });

    tearDown(() async {
      gateway.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<void> pumpScreen(
      WidgetTester tester, {
      Future<Uint8List?> Function()? picker,
    }) async {
      tester.view.physicalSize = const Size(900, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Build inside runAsync so the model list's file IO runs for real.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SettingsScreen(
                controller: gateway,
                settings: settings,
                library: library,
                modelPicker: picker ?? () async => null,
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await _settle(tester);
    }

    testWidgets('changes viewpoint, theme, unit, layers and demo', (
      tester,
    ) async {
      await pumpScreen(tester);
      await tester.tap(find.text('위'));
      await tester.tap(find.text('흐림'));
      await tester.tap(find.text('mph'));
      await tester.tap(find.text('고속도로'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('setting-lanes')));
      await tester.tap(find.byKey(const ValueKey('setting-hud')));
      await tester.tap(find.byKey(const ValueKey('setting-demo')));
      await tester.pump();
      final value = settings.value;
      expect(value.viewpoint, SceneViewpoint.topDown);
      expect(value.sceneTheme, SceneTheme.overcast);
      expect(value.speedUnit, SpeedUnit.mph);
      expect(value.demoRoute, DemoRoute.highway);
      expect(value.showLanes, isFalse);
      expect(value.showHud, isFalse);
      expect(value.demoMode, isFalse);
      expect(find.text('ENABLE_CANFD_LONGITUDINAL_STAGING'), findsNothing);
    });

    testWidgets('rejects a public domain for the device address', (
      tester,
    ) async {
      await pumpScreen(tester);
      await tester.enterText(
        find.byKey(const ValueKey('setting-telemetry-endpoint')),
        'ws://example.com/v1/telemetry',
      );
      await tester.tap(find.byKey(const ValueKey('setting-endpoint-save')));
      await tester.pump();
      expect(find.text('같은 네트워크 안의 주소만 쓸 수 있어요.'), findsOneWidget);
      expect(
        settings.value.telemetryEndpoint,
        AppSettings.defaultTelemetryEndpoint,
      );

      await tester.enterText(
        find.byKey(const ValueKey('setting-telemetry-endpoint')),
        'ws://comma.local:9000/v1/telemetry',
      );
      await tester.tap(find.byKey(const ValueKey('setting-endpoint-save')));
      await tester.pump();
      expect(find.text('저장했어요.'), findsOneWidget);
      expect(
        settings.value.telemetryEndpoint,
        'ws://comma.local:9000/v1/telemetry',
      );
    });

    testWidgets('imports, lists, selects and deletes a model pack', (
      tester,
    ) async {
      await pumpScreen(tester, picker: () async => _validPack());
      expect(
        find.byKey(const ValueKey('model-khronos-toy-car')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('model-kovalink-basic')),
        findsOneWidget,
      );

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('model-import')));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await _settle(tester);
      expect(find.text('차량 모델을 가져왔어요'), findsOneWidget);
      expect(settings.value.vehicleModelId, 'my-import-car');
      await tester.tap(find.text('확인'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('model-my-import-car')), findsOneWidget);
      expect(find.byType(VehicleModelPreview), findsNWidgets(3));

      await tester.tap(find.byKey(const ValueKey('model-kovalink-basic')));
      await tester.pump();
      expect(settings.value.vehicleModelId, 'kovalink-basic');

      await tester.tap(
        find.byKey(const ValueKey('model-delete-my-import-car')),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('model-delete-confirm')));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await _settle(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('model-my-import-car')), findsNothing);
      expect(
        Directory('${root.path}/vehicle_models/my-import-car').existsSync(),
        isFalse,
      );
    });

    testWidgets('shows the rejection reason and stores nothing', (
      tester,
    ) async {
      await pumpScreen(tester, picker: () async => _traversalPack());
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('model-import')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await _settle(tester);
      expect(find.text('이 파일은 가져올 수 없어요'), findsOneWidget);
      expect(find.textContaining('폴더 밖을 가리키는'), findsOneWidget);
      expect(settings.value.vehicleModelId, isNull);
      final models = Directory('${root.path}/vehicle_models');
      expect(models.existsSync() ? models.listSync() : const [], isEmpty);
    });
  });

  group('app wiring', () {
    testWidgets('restored settings drive the road view and demo switch', (
      tester,
    ) async {
      final store = MemorySettingsStore({
        'viewpoint': 'topDown',
        'sceneTheme': 'overcast',
        'speedUnit': 'mph',
        'demoMode': false,
        'brightness': 0.6,
      });
      await tester.pumpWidget(
        KovaLinkApp(
          settingsStore: store,
          storageRoot: () async => Directory.systemTemp,
        ),
      );
      await tester.pump();
      await tester.pump();
      final road = tester.widget<RoadViewScreen>(find.byType(RoadViewScreen));
      expect(road.viewpoint, SceneViewpoint.topDown);
      expect(road.theme, SceneTheme.overcast);
      expect(road.speedUnit, SpeedUnit.mph);
      expect(find.byKey(const ValueKey('road-dimmer')), findsOneWidget);
      // Demo off: idle road, no invented navigation.
      expect(find.text('좌회전'), findsNothing);
      expect(find.text('조향 보조 대기'), findsOneWidget);
      expect(find.byTooltip('차량 모델 가져오기'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
