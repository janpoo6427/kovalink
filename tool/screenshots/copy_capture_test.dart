// Phone-size captures of the screens whose wording was reviewed: settings
// (app tab full length, connection tab), the connect screen (empty and with
// an address error). kovapilot tab states: kova_settings_capture_test.dart;
// drive HUD: app_capture_test.dart (app_phone_*).
//
//   KOVA_SHOT_DIR=out flutter test tool/screenshots/copy_capture_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/connect/connect_screen.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';

import 'shot_support.dart';

const _ratio = 2.625;

ThemeData _theme() => ThemeData(
  fontFamily: 'Roboto',
  brightness: Brightness.dark,
  colorScheme: const ColorScheme.dark(
    primary: Color(0xFF58F2C2),
    surface: Color(0xFF111820),
  ),
  scaffoldBackgroundColor: const Color(0xFF070B10),
  useMaterial3: true,
);

Future<void> _capture(
  WidgetTester tester,
  String name,
  double height,
  Widget Function(GatewayController, SettingsController, VehicleModelLibrary)
  build, {
  Future<void> Function(GatewayController)? setup,
}) async {
  await tester.runAsync(loadReviewFonts);
  tester.view.physicalSize = Size(1080, height);
  tester.view.devicePixelRatio = _ratio;
  addTearDown(tester.view.reset);
  final root = await tester.runAsync(
    () => Directory.systemTemp.createTemp('kl_copy_'),
  );
  final controller = GatewayController();
  final settings = SettingsController(store: MemorySettingsStore());
  final library = VehicleModelLibrary(storageRoot: () async => root!);
  final key = GlobalKey();
  await tester.runAsync(() async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(),
          home: Scaffold(body: build(controller, settings, library)),
        ),
      ),
    );
    if (setup != null) await setup(controller);
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });
  await tester.pump();
  await saveBoundary(tester, key, name, pixelRatio: _ratio);
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  await tester.runAsync(() => root!.delete(recursive: true));
}

void main() {
  testWidgets('capture copy_settings_app_full', (tester) async {
    await _capture(
      tester,
      'copy_settings_app_full',
      5600,
      (controller, settings, library) => SettingsScreen(
        controller: controller,
        settings: settings,
        library: library,
      ),
    );
  });

  testWidgets('capture copy_settings_session_1080x2340', (tester) async {
    await _capture(
      tester,
      'copy_settings_session_1080x2340',
      2340,
      (controller, settings, library) => SettingsScreen(
        controller: controller,
        settings: settings,
        library: library,
        initialTab: SettingsTab.session,
      ),
    );
  });

  testWidgets('capture copy_connect_1080x2340', (tester) async {
    await _capture(
      tester,
      'copy_connect_1080x2340',
      2340,
      (controller, settings, library) =>
          ConnectScreen(controller: controller, settings: settings),
    );
  });

  testWidgets('capture copy_connect_error_1080x2340', (tester) async {
    await _capture(
      tester,
      'copy_connect_error_1080x2340',
      2340,
      (controller, settings, library) =>
          ConnectScreen(controller: controller, settings: settings),
      setup: (controller) async {
        await controller.connect('wss://example.com/v1/telemetry');
      },
    );
  });
}
