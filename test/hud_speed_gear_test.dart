// The top of the drive HUD at every speed and on every background:
//
// - The speed has a 3-digit box: from 0 to 199 the number row, the unit,
//   the gear, the blinker row and the limit sign stay exactly where they
//   are (janpoo 2026-11-25: "속도가 증가함에 따라 레이아웃 영역이 달라지고
//   있어").
// - The speed digits, the unit and every gear letter keep 4.5:1 against
//   what is right around them on a bright sky, snow / a white road and a
//   dark view (night, camera view without a camera), measured on the drawn
//   pixels with the real Korean font.
//
// Only public HUD types are used, so the same file also runs on the build
// from before the fix (where it fails).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/models/display_units.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';

import '../tool/screenshots/shot_support.dart';
import 'support/device_profiles.dart';
import 'support/hud_probe.dart';
import 'support/layout_probe.dart';

Duration _s(double seconds) => Duration(milliseconds: (seconds * 1000).round());

/// km/h that show 0, 9, 10, 99, 100 and 199 in [unit].
List<double> _speedsIn(SpeedUnit unit) => [
  for (final shown in [0, 9, 10, 99, 100, 199]) shown / unit.fromKph(1),
];

final _key = GlobalKey();

Future<void> _pumpAt(
  WidgetTester tester,
  RoadScene base,
  double kph, {
  required Size size,
  SpeedUnit unit = SpeedUnit.kph,
  HudBackdrop backdrop = HudBackdrop.sky,
  VehicleGear gear = VehicleGear.drive,
}) async {
  await tester.pumpWidget(
    hudOn(
      backdrop,
      sceneWith(base, kph: kph, gear: gear),
      boundary: _key,
      compact: size.width < 680,
      unit: unit,
    ),
  );
  await tester.pump();
}

/// Every part's place at each of [speedsKph], checked against the first.
Future<void> _expectPartsStayPut(
  WidgetTester tester, {
  required Size size,
  required SpeedUnit unit,
  required String reason,
}) async {
  final base = DemoDriveScenario().sceneAt(_s(85));
  Map<String, Rect>? first;
  for (final kph in _speedsIn(unit)) {
    await _pumpAt(tester, base, kph, size: size, unit: unit);
    expect(tester.takeException(), isNull, reason: '$reason $kph km/h');
    final shown = '${unit.roundedFromMps(kph / 3.6)}';
    final parts = hudParts(tester, speed: shown)..remove('speedDigits');
    first ??= parts;
    for (final MapEntry(:key, :value) in parts.entries) {
      expect(
        value,
        first[key],
        reason: '$reason: $key at $shown ${unit.label}',
      );
    }
    // The digits are drawn inside the speed's own row, left of the unit
    // (glyph boxes may reach half the -3 letter spacing past the ends).
    final digits = speedGlyphs(tester, shown);
    expect(
      digits.left,
      greaterThanOrEqualTo(parts['numberRow']!.left - 2),
      reason: '$reason: $shown ${unit.label} starts left of its row',
    );
    expect(
      digits.right,
      lessThanOrEqualTo(parts['unit']!.left + 2),
      reason: '$reason: $shown ${unit.label} runs into the unit',
    );
  }
}

/// Road view size of [device] (the home screen keeps the top and side
/// insets clear).
Size _roadOf(DeviceProfile device) => Size(
  device.width - device.padding.left - device.padding.right,
  device.height - device.padding.top,
);

void _useView(WidgetTester tester, Size size, {double dpr = 2}) {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
}

final _realFonts = File(
  '/usr/share/fonts/google-noto-cjk/NotoSansCJKkr-Regular.otf',
).existsSync();

void main() {
  group('speed box (test font)', () {
    for (final size in const [
      Size(392, 850), // phone portrait
      Size(852, 393), // phone on a car mount
      Size(1200, 900), // tablet
    ]) {
      for (final unit in SpeedUnit.values) {
        testWidgets('parts stay put from 0 to 199 ${unit.label} on $size', (
          tester,
        ) async {
          _useView(tester, size, dpr: 1);
          await _expectPartsStayPut(
            tester,
            size: size,
            unit: unit,
            reason: '$size',
          );
        });
      }
    }
  });

  group('speed box and readability (real font)', skip: !_realFonts, () {
    for (final device in allDevices) {
      testWidgets('${device.id}: parts stay put from 0 to 199 km/h', (
        tester,
      ) async {
        await tester.runAsync(loadReviewFonts);
        _useView(tester, _roadOf(device));
        await _expectPartsStayPut(
          tester,
          size: _roadOf(device),
          unit: SpeedUnit.kph,
          reason: device.id,
        );
      });
    }

    for (final device in [portraitDevices.first, landscapeDevices[2]]) {
      testWidgets('${device.id} with 130% text: parts stay put', (
        tester,
      ) async {
        await tester.runAsync(loadReviewFonts);
        _useView(tester, _roadOf(device));
        setTextScale(tester, 1.3);
        addTearDown(() => resetTextScale(tester));
        await _expectPartsStayPut(
          tester,
          size: _roadOf(device),
          unit: SpeedUnit.kph,
          reason: '${device.id} 130%',
        );
      });
    }

    for (final device in [
      portraitDevices[2], // iPhone 15
      landscapeDevices[1], // iPhone 15 on a car mount
      landscapeDevices[7], // iPad Pro 11
    ]) {
      testWidgets('${device.id}: speed, unit and gear read on any view', (
        tester,
      ) async {
        await tester.runAsync(loadReviewFonts);
        final size = _roadOf(device);
        _useView(tester, size);
        final base = DemoDriveScenario().sceneAt(_s(85));
        for (final backdrop in HudBackdrop.values) {
          for (final (kph, gear) in const [
            (9.0, VehicleGear.drive),
            (99.0, VehicleGear.drive),
            (199.0, VehicleGear.drive),
            (0.0, VehicleGear.park),
            (0.0, VehicleGear.reverse),
            (0.0, VehicleGear.neutral),
          ]) {
            await _pumpAt(
              tester,
              base,
              kph,
              size: size,
              backdrop: backdrop,
              gear: gear,
            );
            final pixels = await HudPixels.capture(tester, _key);
            final at = '${backdrop.name} ${kph.round()} km/h ${gear.name}';
            final speed = pixels.contrastIn(
              speedGlyphs(tester, '${kph.round()}'),
            );
            expect(speed.ratio, greaterThanOrEqualTo(4.5), reason: 'speed $at');
            final unit = pixels.contrastIn(unitGlyphs(tester));
            expect(unit.ratio, greaterThanOrEqualTo(4.5), reason: 'unit $at');
            final letters = gearGlyphs(tester);
            expect(letters.keys, containsAll(['P', 'R', 'N', 'D']));
            for (final MapEntry(:key, :value) in letters.entries) {
              expect(
                pixels.contrastIn(value).ratio,
                greaterThanOrEqualTo(4.5),
                reason: 'gear $key $at',
              );
            }
          }
        }
      });
    }
  });
}
