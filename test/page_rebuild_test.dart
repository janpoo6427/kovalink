// Pages that show the connection (설정, 장치 연결) rebuild when the
// connection changes, not on every telemetry frame, and the drive screen
// under them does not rebuild either.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/features/connect/connect_screen.dart';
import 'package:kovalink/src/features/road_view/road_view_screen.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';

/// Widgets rebuilt on their own (not by a parent), per screen.
class _Rebuilds {
  static const screens = [SettingsScreen, ConnectScreen, RoadViewScreen];
  final counts = <Type, int>{};

  static bool _inside(Element element, Type screen) {
    if (element.widget.runtimeType == screen) return true;
    var found = false;
    element.visitAncestorElements((ancestor) {
      found = ancestor.widget.runtimeType == screen;
      return !found;
    });
    return found;
  }

  void start() {
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      for (final screen in screens) {
        if (_inside(element, screen)) {
          counts[screen] = (counts[screen] ?? 0) + 1;
        }
      }
    };
  }

  void stop() => debugOnRebuildDirtyWidget = null;

  int of(Type type) => counts[type] ?? 0;
}

Future<void> _run(WidgetTester tester, Duration time) async {
  for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 50)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    KovaLinkApp(
      settingsStore: MemorySettingsStore(),
      storageRoot: () async => Directory.systemTemp,
      modelPicker: () async => null,
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('status skips telemetry frames and follows connection changes', (
    tester,
  ) async {
    final controller = GatewayController();
    var frames = 0, status = 0;
    controller
      ..addListener(() => frames++)
      ..status.addListener(() => status++);

    controller.startDemo();
    expect(status, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(frames, greaterThanOrEqualTo(40));
    expect(status, 1, reason: 'demo frames are not connection changes');

    controller.startDemo(route: DemoRoute.highway);
    expect(status, 2, reason: 'another demo route');
    controller.stopDemo();
    expect(status, 3);
    expect(await controller.connect('http://example.com'), isNotNull);
    expect(controller.mode, GatewayMode.error);
    expect(status, 4, reason: 'an error shows on the pages');
    controller.dispose();
  });

  testWidgets('설정 stays still while the demo drives; so does the drive '
      'screen under it', (tester) async {
    await _pumpApp(tester);
    final rebuilds = _Rebuilds()..start();
    try {
      await _run(tester, const Duration(seconds: 1));
      expect(
        rebuilds.of(RoadViewScreen),
        greaterThanOrEqualTo(15),
        reason: 'the drive screen follows the demo while shown',
      );

      await tester.tap(find.byTooltip('설정'));
      await _run(tester, const Duration(seconds: 1));
      expect(find.byType(SettingsScreen), findsOneWidget);
      rebuilds.counts.clear();
      await _run(tester, const Duration(seconds: 2));
      expect(rebuilds.of(SettingsScreen), 0);
      expect(rebuilds.of(RoadViewScreen), 0);

      await tester.binding.handlePopRoute();
      await _run(tester, const Duration(seconds: 1));
      expect(find.byType(SettingsScreen), findsNothing);
      rebuilds.counts.clear();
      await _run(tester, const Duration(seconds: 1));
      expect(rebuilds.of(RoadViewScreen), greaterThanOrEqualTo(15));
    } finally {
      rebuilds.stop();
    }
    await _done(tester);
  });

  testWidgets('장치 연결 stays still while the demo drives', (tester) async {
    await _pumpApp(tester);
    final rebuilds = _Rebuilds()..start();
    try {
      await tester.tap(find.byTooltip('장치 연결'));
      await _run(tester, const Duration(seconds: 1));
      expect(find.byType(ConnectScreen), findsOneWidget);
      rebuilds.counts.clear();
      await _run(tester, const Duration(seconds: 2));
      expect(rebuilds.of(ConnectScreen), 0);
      expect(rebuilds.of(RoadViewScreen), 0);
    } finally {
      rebuilds.stop();
    }
    await _done(tester);
  });
}
