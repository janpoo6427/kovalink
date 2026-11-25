// Layout on phone, foldable and tablet sizes, portrait and landscape, with
// each device's system insets: no layout errors (RenderFlex overflow etc.),
// drive HUD parts on screen, out of the insets and not covering each other
// or the buttons, the camera notice clear of the HUD and of the right
// middle (a navigation app's overlay), the blinkers in the same spot with
// and without a traffic light, the back button clear of page text, and
// button labels on one line. Sizes: test/support/device_profiles.dart.
//
// Text widths matter here, so the real Korean font (Noto Sans CJK KR, on
// the worker) is loaded; without it the test font draws every glyph 1 em
// wide and the size checks are skipped.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/app/kovalink_home.dart';
import 'package:kovalink/src/features/road_view/hud/drive_hud.dart';
import 'package:kovalink/src/features/road_view/road_view_screen.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';

import '../tool/screenshots/shot_support.dart';
import 'support/device_profiles.dart';
import 'support/fake_kova_gateway.dart';
import 'support/layout_probe.dart';

Duration _s(double seconds) => Duration(milliseconds: (seconds * 1000).round());

// Screen changes are routes now (the platform page transition takes
// 450 ms, plus a frame to take the old page away), so wait one more frame.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<KovaParamsController> _pumpHome(
  WidgetTester tester,
  Directory root, {
  DemoRoute route = DemoRoute.city,
  double t = 85,
}) async {
  final controller = GatewayController()
    ..scene = DemoDriveScenario(route: route).sceneAt(_s(t));
  addTearDown(controller.dispose);
  final gateway = FakeKovaGateway();
  final kova = KovaParamsController(
    clientFactory: (endpoint, onError) => KovaParamsClient.tryCreate(
      endpoint,
      transport: gateway,
      onError: onError,
    ),
    pollInterval: null,
  );
  addTearDown(kova.dispose);
  final settings = SettingsController(
    store: MemorySettingsStore(),
    initial: AppSettings(
      demoRoute: route,
      lastDeviceEndpoint: 'http://127.0.0.1:18082',
    ),
  );
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        theme: KovaLinkApp.theme(Brightness.dark),
        home: KovaLinkHome(
          controller: controller,
          settings: settings,
          library: VehicleModelLibrary(storageRoot: () async => root),
          kovaParams: kova,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pump();
  return kova;
}

/// Scrolls the visible list to the end, checking text on the way.
Future<void> _scrollThrough(WidgetTester tester, LayoutReport report) async {
  final scrollable = find.byType(Scrollable).hitTestable();
  if (scrollable.evaluate().isEmpty) return;
  final position = tester.state<ScrollableState>(scrollable.first).position;
  for (var i = 0; i < 40; i++) {
    checkVisibleText(tester, report);
    if (position.pixels >= position.maxScrollExtent - 1) break;
    position.jumpTo(
      (position.pixels + position.viewportDimension * 0.8).clamp(
        0,
        position.maxScrollExtent,
      ),
    );
    await tester.pump();
  }
  position.jumpTo(0);
  await tester.pump();
}

Future<List<String>> _checkDevice(
  WidgetTester tester,
  DeviceProfile device, {
  double textScale = 1,
}) async {
  await tester.runAsync(loadReviewFonts);
  device.apply(tester);
  addTearDown(tester.view.reset);
  if (textScale != 1) {
    setTextScale(tester, textScale);
    addTearDown(() => resetTextScale(tester));
  }
  final root = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('kl_layout_'),
  ))!;
  addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
  final report = LayoutReport();
  final tabs = find.byKey(const ValueKey('settings-tabs'));
  report.errors.addAll(
    await collectFlutterErrors(() async {
      for (final (route, t) in [
        (DemoRoute.city, 85.0),
        (DemoRoute.highway, 20.0),
      ]) {
        await _pumpHome(tester, root, route: route, t: t);
        expect(find.byType(DriveHud), findsOneWidget);
        checkDriveScreen(tester, report);
        await tester.pumpWidget(const SizedBox.shrink());
      }

      // Camera view without a camera: the notice card.
      await _pumpHome(tester, root);
      await tester.tap(find.byTooltip('카메라 화면으로 바꾸기'));
      await tester.pump();
      expect(find.byKey(const ValueKey('camera-notice')), findsOneWidget);
      checkDriveScreen(tester, report);
      await tester.pumpWidget(const SizedBox.shrink());

      await _pumpHome(tester, root);
      await tester.tap(find.byTooltip('장치 연결'));
      await _settle(tester);
      checkBackButton(tester, report);
      await _scrollThrough(tester, report);

      await tester.tap(find.byTooltip('주행 화면으로 돌아가기'));
      await _settle(tester);
      await tester.tap(find.byTooltip('설정'));
      await _settle(tester);
      checkBackButton(tester, report);
      await _scrollThrough(tester, report);

      await tester.tap(find.descendant(of: tabs, matching: find.text('연결 상태')));
      await _settle(tester);
      await _scrollThrough(tester, report);

      await tester.tap(
        find.descendant(of: tabs, matching: find.text('kovapilot')),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('kova-connect')));
      await _settle(tester);
      await _scrollThrough(tester, report);
      await tester.pumpWidget(const SizedBox.shrink());
    }),
  );
  return report.problems.toSet().toList();
}

final _realFonts = File(
  '/usr/share/fonts/google-noto-cjk/NotoSansCJKkr-Regular.otf',
).existsSync();

void main() {
  group('device layout', skip: !_realFonts, () {
    for (final device in allDevices) {
      testWidgets('${device.id} (${device.label})', (tester) async {
        expect(await _checkDevice(tester, device), isEmpty);
      });
    }

    for (final device in [portraitDevices.first, landscapeDevices[2]]) {
      testWidgets('${device.id} with 130% text', (tester) async {
        expect(await _checkDevice(tester, device, textScale: 1.3), isEmpty);
      });
    }

    for (final device in allDevices) {
      testWidgets('${device.id} blinkers stay put with or without a light', (
        tester,
      ) async {
        await tester.runAsync(loadReviewFonts);
        device.apply(tester);
        addTearDown(tester.view.reset);
        final root = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('kl_layout_'),
        ))!;
        addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
        Rect? left;
        Rect? right;
        // No light (58 s), green (61 s), yellow (79 s), red with a long
        // count (85 s), red at the stop line (0.5 s), green arrow (7 s).
        for (final (t, light) in [
          (58.0, false),
          (61.0, true),
          (79.0, true),
          (85.0, true),
          (0.5, true),
          (7.0, true),
        ]) {
          await _pumpHome(tester, root, t: t);
          expect(
            find.byKey(const ValueKey('traffic-light-slot')),
            light ? findsOneWidget : findsNothing,
            reason: '$t s',
          );
          final l = tester.getRect(find.byKey(const ValueKey('blinker-left')));
          final r = tester.getRect(find.byKey(const ValueKey('blinker-right')));
          left ??= l;
          right ??= r;
          expect(l, left, reason: 'left blinker at $t s');
          expect(r, right, reason: 'right blinker at $t s');
          await tester.pumpWidget(const SizedBox.shrink());
        }
      });
    }

    testWidgets('the app keeps notices out of the same zone the check uses', (
      tester,
    ) async {
      for (final device in allDevices) {
        final road =
            Offset(device.padding.left, device.padding.top) &
            Size(
              device.width - device.padding.left - device.padding.right,
              device.height - device.padding.top,
            );
        final layout = HudLayout(
          road.size,
          compact: road.width < 680,
          showNumbers: true,
        );
        expect(
          layout.navOverlayZone.shift(road.topLeft),
          navOverlayZoneOf(road),
          reason: device.id,
        );
        for (final showNumbers in [true, false]) {
          final notice = HudLayout(
            road.size,
            compact: road.width < 680,
            showNumbers: showNumbers,
            bottomInset: device.padding.bottom,
          ).noticeArea.area;
          expect(notice.width, greaterThan(100), reason: device.id);
          expect(notice.height, greaterThan(60), reason: device.id);
          final hit = notice.intersect(layout.navOverlayZone);
          expect(
            hit.width <= 0 || hit.height <= 0,
            isTrue,
            reason: '${device.id} notice $notice',
          );
        }
      }
    });

    testWidgets('camera notice sits under the overlay zone on a phone', (
      tester,
    ) async {
      final device = portraitDevices[2]; // iPhone 15
      await tester.runAsync(loadReviewFonts);
      device.apply(tester);
      addTearDown(tester.view.reset);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('kl_layout_'),
      ))!;
      addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
      await _pumpHome(tester, root);
      await tester.tap(find.byTooltip('카메라 화면으로 바꾸기'));
      await tester.pump();
      final notice = tester.getRect(
        find.byKey(const ValueKey('camera-notice')),
      );
      final signal = tester.getRect(find.byType(SignalPill));
      final buttons = tester.getRect(find.byTooltip('설정'));
      expect(notice.top, greaterThan(signal.bottom));
      expect(notice.bottom, lessThan(buttons.top));
      final road = tester.getRect(find.byType(RoadViewScreen));
      expect(notice.top, greaterThan(navOverlayZoneOf(road).bottom));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('landscape phone puts the camera notice under the speed', (
      tester,
    ) async {
      final device = landscapeDevices[1];
      await tester.runAsync(loadReviewFonts);
      device.apply(tester);
      addTearDown(tester.view.reset);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('kl_layout_'),
      ))!;
      addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
      await _pumpHome(tester, root);
      await tester.tap(find.byTooltip('카메라 화면으로 바꾸기'));
      await tester.pump();
      final notice = tester.getRect(
        find.byKey(const ValueKey('camera-notice')),
      );
      final settingsButton = tester.getRect(find.byTooltip('설정'));
      final speed = tester.getRect(find.byType(SpeedCluster));
      final road = tester.getRect(find.byType(RoadViewScreen));
      // Under the speed, left of the overlay zone, above the buttons.
      expect(notice.top, greaterThan(speed.bottom));
      expect(notice.right, lessThan(navOverlayZoneOf(road).left));
      expect(notice.bottom, lessThan(settingsButton.top));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('settings and connect keep a readable width on tablets', (
      tester,
    ) async {
      final device = landscapeDevices.last; // iPad Pro 12.9 landscape
      await tester.runAsync(loadReviewFonts);
      device.apply(tester);
      addTearDown(tester.view.reset);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('kl_layout_'),
      ))!;
      addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
      await _pumpHome(tester, root);
      await tester.tap(find.byTooltip('설정'));
      await _settle(tester);
      final tabs = tester.getRect(find.byKey(const ValueKey('settings-tabs')));
      expect(tabs.width, lessThanOrEqualTo(720));
      // Centered in the space beside the insets.
      final mid =
          (device.padding.left + device.width - device.padding.right) / 2;
      expect((tabs.center.dx - mid).abs(), lessThan(1));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('bottom buttons sit above the home indicator', (tester) async {
      final device = portraitDevices[2]; // iPhone 15: 34 dp indicator
      await tester.runAsync(loadReviewFonts);
      device.apply(tester);
      addTearDown(tester.view.reset);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('kl_layout_'),
      ))!;
      addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
      await _pumpHome(tester, root);
      final limit = device.height - device.padding.bottom;
      expect(tester.getRect(find.byTooltip('설정')).bottom, lessThan(limit));
      expect(
        tester.getRect(find.byTooltip('카메라 화면으로 바꾸기')).bottom,
        lessThan(limit),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
