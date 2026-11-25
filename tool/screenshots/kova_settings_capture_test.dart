// Captures of the kovapilot settings tab in each connection/sending state.
// Uses the in-memory gateway from test/support with the e2e fixture
// catalog (its "통신 시험용" group is fake test data).
//
//   KOVA_SHOT_DIR=out flutter test tool/screenshots/kova_settings_capture_test.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';

import '../../test/support/fake_kova_gateway.dart';
import 'shot_support.dart';

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

typedef _Setup =
    Future<void> Function(
      WidgetTester tester,
      KovaParamsController kova,
      FakeKovaGateway gateway,
    );

Future<void> _scrollTo(
  WidgetTester tester,
  String key, {
  double up = 120,
}) async {
  await tester.scrollUntilVisible(
    find.byKey(ValueKey(key)),
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.drag(find.byType(Scrollable).first, Offset(0, -up));
  await tester.pump();
}

void main() {
  const loopback = 'http://127.0.0.1:18082';
  final shots = <(String, String, _Setup?)>[
    ('kova_01_disconnected', loopback, null),
    (
      'kova_02_lan_readonly',
      'http://comma.local:8082',
      (tester, kova, gateway) async {
        await tester.tap(find.byKey(const ValueKey('kova-connect')));
        await tester.pump();
      },
    ),
    (
      'kova_03_loopback_editable',
      loopback,
      (tester, kova, gateway) async {
        await tester.tap(find.byKey(const ValueKey('kova-connect')));
        await tester.pump();
      },
    ),
    (
      'kova_04_confirm_dialog',
      loopback,
      (tester, kova, gateway) async {
        await tester.tap(find.byKey(const ValueKey('kova-connect')));
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('kova-toggle-steering.always_on')),
        );
        await tester.pumpAndSettle();
      },
    ),
    (
      'kova_05_sending',
      loopback,
      (tester, kova, gateway) async {
        await tester.tap(find.byKey(const ValueKey('kova-connect')));
        await tester.pump();
        gateway.hold = Completer<void>();
        await tester.tap(
          find.byKey(const ValueKey('kova-toggle-steering.always_on')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('kova-confirm-change')));
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
      },
    ),
    (
      'kova_06_applied_details',
      loopback,
      (tester, kova, gateway) async {
        await tester.tap(find.byKey(const ValueKey('kova-connect')));
        await tester.pump();
        await kova.setValue('steering.always_on', true);
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('kova-more-steering.always_on')),
        );
        await tester.pump();
      },
    ),
    (
      'kova_07_conflict',
      loopback,
      (tester, kova, gateway) async {
        await tester.tap(find.byKey(const ValueKey('kova-connect')));
        await tester.pump();
        gateway.externalWrite('e2e.level', 9);
        await kova.setValue('e2e.level', 4);
        await tester.pump();
        await _scrollTo(tester, 'kova-notice-e2e.level', up: 260);
      },
    ),
    (
      'kova_08_rejected_onroad',
      loopback,
      (tester, kova, gateway) async {
        gateway
          ..offroad = false
          ..reportOffroad = false;
        await tester.tap(find.byKey(const ValueKey('kova-connect')));
        await tester.pump();
        await kova.setValue('steering.always_on', true);
        await tester.pump();
      },
    ),
    (
      'kova_09_onroad_locked',
      loopback,
      (tester, kova, gateway) async {
        gateway.offroad = false;
        await tester.tap(find.byKey(const ValueKey('kova-connect')));
        await tester.pump();
      },
    ),
    (
      'kova_10_stale',
      loopback,
      (tester, kova, gateway) async {
        await tester.tap(find.byKey(const ValueKey('kova-connect')));
        await tester.pump();
        gateway.down = true;
        await kova.refresh();
        await tester.pump();
      },
    ),
    (
      'kova_11_choice_sheet',
      loopback,
      (tester, kova, gateway) async {
        await tester.tap(find.byKey(const ValueKey('kova-connect')));
        await tester.pump();
        await _scrollTo(tester, 'kova-choice-e2e.mode', up: 200);
        await tester.tap(find.byKey(const ValueKey('kova-choice-e2e.mode')));
        await tester.pumpAndSettle();
      },
    ),
  ];

  for (final (name, address, setup) in shots) {
    testWidgets('capture $name', (tester) async {
      await tester.runAsync(loadReviewFonts);
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final gateway = FakeKovaGateway();
      final kova = KovaParamsController(
        clientFactory: (endpoint, onError) => KovaParamsClient.tryCreate(
          endpoint,
          transport: gateway,
          onError: onError,
        ),
        pollInterval: null,
      );
      final controller = GatewayController();
      final settings = SettingsController(
        store: MemorySettingsStore(),
        initial: AppSettings(lastDeviceEndpoint: address),
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(),
            home: Scaffold(
              body: SettingsScreen(
                controller: controller,
                settings: settings,
                kovaParams: kova,
                initialTab: SettingsTab.kovapilot,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      if (setup != null) await setup(tester, kova, gateway);
      await saveBoundary(tester, key, name, pixelRatio: 2.625);
      gateway.hold?.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      kova.dispose();
      controller.dispose();
    });
  }
}
