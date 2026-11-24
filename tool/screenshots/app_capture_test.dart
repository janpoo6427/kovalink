import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/road_view_screen.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';

import 'shot_support.dart';

Duration _s(double seconds) => Duration(milliseconds: (seconds * 1000).round());

/// Full road-view screen (scene + HUD) at reference compositions.
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
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'Roboto', useMaterial3: true),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: SafeArea(
                child: RoadViewScreen(
                  controller: controller,
                  theme: theme,
                  viewpoint: viewpoint,
                ),
              ),
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
}
