// Drive HUD readability and the fixed 3-digit speed box: the HUD over a
// bright sky, snow / a white road and a dark view (night, camera view with
// no camera), at speeds 0 to 199, on a portrait phone, a landscape phone
// (car mount) and a landscape tablet.
//
// Saves one PNG per device, backdrop and speed (9, 99, 199 and 0 in P) and
// $KOVA_SHOT_DIR/hud_report.json: where the speed digits, unit, gear,
// blinkers and limit sign sit at 0, 9, 10, 99, 100 and 199 km/h (and how
// far each moved), and the contrast measured on the drawn pixels of the
// speed digits and of each gear letter against what is right around them.
//
//   KOVA_SHOT_DIR=out flutter test tool/screenshots/hud_speed_gear_capture_test.dart
//   KOVA_BEFORE_DIR=dir   the same captures from the baseline build: adds
//                         before/after sheets (sheets/hud_<device>.png)
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';

import '../../test/support/hud_probe.dart';
import 'shot_support.dart';

Duration _s(double seconds) => Duration(milliseconds: (seconds * 1000).round());

/// Road view sizes (dp) and the part of the capture the sheets show.
const _devices = <(String, String, Size, double)>[
  ('phone_393x852', 'iPhone 15 세로', Size(393, 852), 205),
  ('phone_852x393', 'iPhone 15 가로(거치대)', Size(852, 393), 140),
  ('tablet_1194x834', 'iPad Pro 11 가로', Size(1194, 834), 140),
];

const _speeds = [0.0, 9.0, 10.0, 99.0, 100.0, 199.0];
const _shotSpeeds = [9.0, 99.0, 199.0];
const _pixelRatio = 2.0;

final _key = GlobalKey();

Map<String, Object> _rect(Rect r) => {
  'l': _round(r.left),
  't': _round(r.top),
  'r': _round(r.right),
  'b': _round(r.bottom),
};

double _round(double v) => (v * 100).round() / 100;

void main() {
  final before = Platform.environment['KOVA_BEFORE_DIR'];
  final report = <String, Object>{};

  tearDownAll(() {
    final file = File('$shotDirectory/hud_report.json');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  });

  for (final (id, label, size, _) in _devices) {
    testWidgets('hud $id', (tester) async {
      await tester.runAsync(loadReviewFonts);
      tester.view.physicalSize = size * _pixelRatio;
      tester.view.devicePixelRatio = _pixelRatio;
      addTearDown(tester.view.reset);
      final base = DemoDriveScenario().sceneAt(_s(85));
      final perBackdrop = <String, Object>{};
      for (final backdrop in HudBackdrop.values) {
        final perSpeed = <String, Object>{};
        final first = <String, Rect>{};
        final moved = <String, double>{};
        Future<void> shoot(double kph, VehicleGear gear, String? name) async {
          final scene = sceneWith(base, kph: kph, gear: gear);
          await tester.pumpWidget(
            hudOn(backdrop, scene, boundary: _key, compact: size.width < 680),
          );
          await tester.pump();
          final speed = '${kph.round()}';
          final parts = hudParts(tester, speed: speed);
          final pixels = await HudPixels.capture(
            tester,
            _key,
            pixelRatio: _pixelRatio,
          );
          final digits = pixels.contrastIn(parts['speedDigits']!);
          final unitContrast = pixels.contrastIn(unitGlyphs(tester));
          final gears = {
            for (final MapEntry(:key, :value) in gearGlyphs(tester).entries)
              key: _round(pixels.contrastIn(value).ratio),
          };
          final entry = <String, Object>{
            'gear': gear.name,
            'parts': {
              for (final MapEntry(:key, :value) in parts.entries)
                key: _rect(value),
            },
            'speedContrast': _round(digits.ratio),
            'unitContrast': _round(unitContrast.ratio),
            'gearContrast': gears,
          };
          if (gear == VehicleGear.drive) {
            for (final MapEntry(:key, :value) in parts.entries) {
              if (key == 'speedDigits') continue;
              final at = first[key] ??= value;
              moved[key] = math.max(
                moved[key] ?? 0,
                [
                  (value.left - at.left).abs(),
                  (value.top - at.top).abs(),
                  (value.right - at.right).abs(),
                  (value.bottom - at.bottom).abs(),
                ].reduce(math.max),
              );
            }
          }
          perSpeed[name ?? speed] = entry;
          if (name != null || _shotSpeeds.contains(kph)) {
            await saveBoundary(
              tester,
              _key,
              '$id/${backdrop.name}_${name ?? speed}',
              pixelRatio: _pixelRatio,
            );
          }
        }

        for (final kph in _speeds) {
          await shoot(kph, VehicleGear.drive, null);
        }
        await shoot(0, VehicleGear.park, '0_P');
        await shoot(0, VehicleGear.reverse, '0_R');
        perBackdrop[backdrop.name] = {
          'label': backdrop.label,
          'movedPx': {
            for (final MapEntry(:key, :value) in moved.entries)
              key: _round(value),
          },
          'speeds': perSpeed,
        };
        await tester.pumpWidget(const SizedBox.shrink());
      }
      report[id] = {
        'label': label,
        'size': '${size.width.round()}x${size.height.round()}',
        'backdrops': perBackdrop,
      };
    });
  }

  if (before != null) {
    testWidgets('before/after sheets', (tester) async {
      await tester.runAsync(loadReviewFonts);
      final beforeReport = _readReport('$before/hud_report.json');
      final afterReport = _readReport('$shotDirectory/hud_report.json');
      for (final (id, label, size, cropHeight) in _devices) {
        final rows = <(String, ui.Image?, ui.Image?, double?, double?)>[];
        for (final backdrop in HudBackdrop.values) {
          for (final name in [
            for (final s in _shotSpeeds) '${s.round()}',
            '0_P',
          ]) {
            final b = await _load(
              tester,
              '$before/$id/${backdrop.name}_$name.png',
            );
            final a = await _load(
              tester,
              '$shotDirectory/$id/${backdrop.name}_$name.png',
            );
            rows.add((
              '${backdrop.label} · ${name.replaceAll('_', ' ')} km/h',
              b,
              a,
              _unitLeft(beforeReport, id, backdrop.name),
              _unitLeft(afterReport, id, backdrop.name),
            ));
          }
        }
        final crop = Rect.fromLTWH(0, 0, size.width, cropHeight);
        const scale = 1.0;
        const gap = 10.0;
        const labelHeight = 26.0;
        final cellW = crop.width * scale;
        final cellH = crop.height * scale;
        final sheetW = 2 * cellW + 3 * gap;
        final sheetH = 40 + rows.length * (cellH + labelHeight + gap) + gap;
        tester.view.physicalSize = Size(sheetW, sheetH) * 1.5;
        tester.view.devicePixelRatio = 1.5;
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: RepaintBoundary(
              key: _key,
              child: Material(
                color: const Color(0xFF2A2F36),
                child: Padding(
                  padding: const EdgeInsets.all(gap),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 30,
                        child: Row(
                          children: [
                            SizedBox(
                              width: cellW + gap,
                              child: Text(
                                '전 (기준) — $label',
                                style: _labelStyle,
                              ),
                            ),
                            Text('후 (3자리 고정·기어 판)', style: _labelStyle),
                          ],
                        ),
                      ),
                      for (final (title, b, a, bx, ax) in rows) ...[
                        SizedBox(
                          height: labelHeight,
                          child: Text(title, style: _smallStyle),
                        ),
                        Row(
                          children: [
                            _cell(b, crop, cellW, cellH, bx),
                            const SizedBox(width: gap),
                            _cell(a, crop, cellW, cellH, ax),
                          ],
                        ),
                        const SizedBox(height: gap),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await saveBoundary(tester, _key, 'sheets/hud_$id', pixelRatio: 1.5);
      }
      tester.view.reset();
    });
  }
}

const _labelStyle = TextStyle(
  color: Colors.white,
  fontSize: 15,
  fontWeight: FontWeight.w700,
);
const _smallStyle = TextStyle(color: Color(0xFFD0D6DC), fontSize: 12);

Map<String, dynamic>? _readReport(String path) {
  final file = File(path);
  return file.existsSync()
      ? jsonDecode(file.readAsStringSync()) as Map<String, dynamic>
      : null;
}

/// Left edge of the unit at 199 km/h: the guide line on every row, so a
/// unit that moves with the speed shows off the line.
double? _unitLeft(Map<String, dynamic>? report, String id, String backdrop) {
  try {
    final speeds =
        (report![id]['backdrops'][backdrop]['speeds'] as Map<String, dynamic>);
    return (speeds['199']['parts']['unit']['l'] as num).toDouble();
  } on Object {
    return null;
  }
}

Future<ui.Image?> _load(WidgetTester tester, String path) async {
  final file = File(path);
  if (!file.existsSync()) return null;
  return tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
    return (await codec.getNextFrame()).image;
  });
}

Widget _cell(ui.Image? image, Rect crop, double w, double h, double? markX) =>
    SizedBox(
      width: w,
      height: h,
      child: image == null
          ? const ColoredBox(
              color: Color(0xFF555555),
              child: Center(child: Text('없음', style: _smallStyle)),
            )
          : CustomPaint(painter: _CropPainter(image, crop, markX)),
    );

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.crop, this.markX);

  final ui.Image image;
  final Rect crop;
  final double? markX;

  @override
  void paint(Canvas canvas, Size size) {
    const s = _pixelRatio;
    final src = Rect.fromLTRB(
      crop.left * s,
      crop.top * s,
      crop.right * s,
      crop.bottom * s,
    );
    canvas.drawImageRect(
      image,
      src,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    if (markX case final x?) {
      final dx = (x - crop.left) * size.width / crop.width;
      final paint = Paint()
        ..color = const Color(0xFFFF3B6B)
        ..strokeWidth = 1;
      for (var y = 0.0; y < size.height; y += 8) {
        canvas.drawLine(Offset(dx, y), Offset(dx, y + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.image != image;
}
