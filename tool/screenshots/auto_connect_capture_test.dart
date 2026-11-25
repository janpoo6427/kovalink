// Captures of 자동 연결: road-view status chip and the connection screen
// (networks, search progress, found devices, activity log). Fake networks
// and a fake probe; no real network is touched.
//
//   KOVA_SHOT_DIR=out flutter test tool/screenshots/auto_connect_capture_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kovalink_home.dart';
import 'package:kovalink/src/features/connect/connect_screen.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';

import '../../test/support/fake_auto_connect.dart';
import 'shot_support.dart';

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

final _wifi = LocalNetwork.named('wlan0', '192.168.43.120');
final _hotspot = LocalNetwork.named('swlan0', '10.155.70.1');
final _cell = LocalNetwork.named('rmnet_data0', '10.20.30.40');

typedef _Setup = Future<void> Function(WidgetTester tester, FakeProbe probe);

AutoConnectController _auto(FakeProbe probe, List<LocalNetwork> nets) {
  var tick = 0;
  final base = DateTime(2026, 11, 25, 13, 5, 2);
  return AutoConnectController(
    target: FakeTarget(),
    probe: probe,
    listNetworks: () async => nets,
    lastEndpoint: () => 'http://192.168.43.77:8082',
    clock: () => base.add(Duration(milliseconds: 420 * tick++)),
  );
}

Future<void> _run(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 100);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

void main() {
  final connectShots = <(String, List<LocalNetwork>, _Setup)>[
    (
      'auto_connect_1_searching',
      [_wifi, _cell],
      (tester, probe) async {
        probe
          ..delay = const Duration(milliseconds: 300)
          ..other('192.168.43.1');
        await _run(tester, const Duration(milliseconds: 1700));
      },
    ),
    (
      'auto_connect_2_found',
      [_hotspot, _cell],
      (tester, probe) async {
        probe
          ..device('10.155.70.23')
          ..device('10.155.70.140');
        await _run(tester, const Duration(seconds: 1));
      },
    ),
    (
      'auto_connect_3_connected',
      [_wifi, _cell],
      (tester, probe) async {
        probe
          ..other('192.168.43.1')
          ..device('192.168.43.88');
        await _run(tester, const Duration(seconds: 1));
      },
    ),
    (
      'auto_connect_4_retry',
      [_wifi, _cell],
      (tester, probe) async {
        probe.other('192.168.43.1');
        // Passes 1-4 find nothing (waits 1, 2, 5 s); then it waits 10 s.
        await _run(tester, const Duration(seconds: 9));
      },
    ),
    (
      'auto_connect_5_mobile_data_only',
      [_cell],
      (tester, probe) async {
        await _run(tester, const Duration(seconds: 9));
      },
    ),
  ];

  for (final (name, nets, setup) in connectShots) {
    testWidgets('capture $name', (tester) async {
      await tester.runAsync(loadReviewFonts);
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final probe = FakeProbe();
      final auto = _auto(probe, nets);
      final controller = GatewayController();
      final settings = SettingsController(store: MemorySettingsStore());
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.dark),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: SafeArea(
                child: ConnectScreen(
                  controller: controller,
                  settings: settings,
                  autoConnect: auto,
                ),
              ),
            ),
          ),
        ),
      );
      auto.setEnabled(true);
      await setup(tester, probe);
      await tester.pump();
      await saveBoundary(tester, key, name, pixelRatio: 2.625);
      await tester.pumpWidget(const SizedBox.shrink());
      auto.dispose();
      controller.dispose();
      settings.dispose();
      await tester.pump(const Duration(seconds: 1));
    });
  }

  final homeShots = <(String, bool)>[
    ('auto_home_searching_1080x2340', false),
    ('auto_home_connected_1080x2340', true),
  ];
  for (final (name, connected) in homeShots) {
    testWidgets('capture $name', (tester) async {
      await tester.runAsync(loadReviewFonts);
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final probe = FakeProbe()..delay = const Duration(milliseconds: 300);
      if (connected) probe.device('192.168.43.77');
      final auto = _auto(probe, [_wifi, _cell]);
      final controller = GatewayController();
      controller.scene = DemoDriveScenario(
        route: DemoRoute.highway,
      ).sceneAt(const Duration(seconds: 75));
      final settings = SettingsController(store: MemorySettingsStore());
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
              autoConnect: auto,
            ),
          ),
        ),
      );
      auto.setEnabled(true);
      await _run(tester, const Duration(milliseconds: 1200));
      await saveBoundary(tester, key, name, pixelRatio: 2.625);
      await tester.pumpWidget(const SizedBox.shrink());
      auto.dispose();
      controller.dispose();
      settings.dispose();
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
