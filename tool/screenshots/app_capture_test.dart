import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kovalink_home.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';

import 'shot_support.dart';

Duration _s(double seconds) => Duration(milliseconds: (seconds * 1000).round());

ThemeData _theme(Brightness brightness) => ThemeData(
  fontFamily: 'Roboto',
  brightness: brightness,
  colorScheme: brightness == Brightness.dark
      ? const ColorScheme.dark(
          primary: Color(0xFF58F2C2),
          surface: Color(0xFF111820),
        )
      : null,
  scaffoldBackgroundColor: brightness == Brightness.dark
      ? const Color(0xFF070B10)
      : null,
  useMaterial3: true,
);

/// Full home screen (scene + HUD + buttons) at reference compositions.
void main() {
  final shots =
      <(String, Size, double, DemoRoute, double, SceneTheme, SceneViewpoint)>[
        (
          'app_highway_clear_1200x945',
          const Size(1200, 945),
          1,
          DemoRoute.highway,
          75,
          SceneTheme.clear,
          SceneViewpoint.chase,
        ),
        (
          'app_highway_lead_approach_1200x945',
          const Size(1200, 945),
          1,
          DemoRoute.highway,
          44,
          SceneTheme.clear,
          SceneViewpoint.chase,
        ),
        (
          'app_city_overcast_1081x1200',
          const Size(1081, 1200),
          1,
          DemoRoute.city,
          85,
          SceneTheme.overcast,
          SceneViewpoint.chase,
        ),
        (
          'app_city_clear_curve_1081x1200',
          const Size(1081, 1200),
          1,
          DemoRoute.city,
          29,
          SceneTheme.clear,
          SceneViewpoint.chase,
        ),
        (
          'app_phone_highway_1080x2340',
          const Size(1080, 2340),
          2.625,
          DemoRoute.highway,
          75,
          SceneTheme.clear,
          SceneViewpoint.chase,
        ),
        (
          'app_phone_city_overcast_1080x2340',
          const Size(1080, 2340),
          2.625,
          DemoRoute.city,
          2,
          SceneTheme.overcast,
          SceneViewpoint.chase,
        ),
        (
          'app_topdown_1200x945',
          const Size(1200, 945),
          1,
          DemoRoute.highway,
          55,
          SceneTheme.clear,
          SceneViewpoint.topDown,
        ),
        (
          'app_driver_1200x945',
          const Size(1200, 945),
          1,
          DemoRoute.city,
          45,
          SceneTheme.clear,
          SceneViewpoint.driver,
        ),
      ];

  for (final (name, size, ratio, route, t, theme, viewpoint) in shots) {
    testWidgets('capture $name', (tester) async {
      await tester.runAsync(loadReviewFonts);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = ratio;
      addTearDown(tester.view.reset);
      final controller = GatewayController();
      controller.scene = DemoDriveScenario(route: route).sceneAt(_s(t));
      final settings = SettingsController(
        store: MemorySettingsStore(),
        initial: AppSettings(
          viewpoint: viewpoint,
          sceneTheme: theme,
          demoRoute: route,
        ),
      );
      final library = VehicleModelLibrary(
        storageRoot: () async => Directory.systemTemp,
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          home: RepaintBoundary(
            key: key,
            child: KovaLinkHome(
              controller: controller,
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
    });
  }

  testWidgets('capture settings screen', (tester) async {
    await tester.runAsync(loadReviewFonts);
    tester.view.physicalSize = const Size(1080, 5600);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('kl_shot_'),
    );
    final controller = GatewayController();
    final settings = SettingsController(store: MemorySettingsStore());
    final library = VehicleModelLibrary(storageRoot: () async => root!);
    final key = GlobalKey();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.dark),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: SettingsScreen(
                controller: controller,
                settings: settings,
                library: library,
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    await saveBoundary(tester, key, 'app_settings_screen_1080');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.runAsync(() => root!.delete(recursive: true));
  });
}
