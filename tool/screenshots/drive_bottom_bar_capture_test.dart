// Captures of the drive screen's bottom bar (view mode button, 자동 연결
// chip, round buttons) for review: the 16:39 phone in every chip wording,
// and every device in portrait and landscape with the reported wording and
// the longest one, in the camera view (its notice card) and the 3D view.
// Also writes report.json (chip and button rects, overlaps) and, with
// KOVA_BEFORE_DIR pointing at captures of the old build, before/after
// sheets. Runs on old builds too (only uses KovaLinkHome's autoConnect).
//
//   KOVA_SHOT_DIR=out flutter test tool/screenshots/drive_bottom_bar_capture_test.dart
//   KOVA_BEFORE_DIR=dir   captures of the old build: adds before/after sheets
//   KOVA_SHEETS=0         captures only
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/app/kovalink_home.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';

import '../../test/support/device_profiles.dart';
import '../../test/support/drive_bar_fixtures.dart';
import 'shot_support.dart';

final _key = GlobalKey();
final _chip = find.byKey(const ValueKey('auto-connect-chip'));
const _modeTips = ['카메라 화면으로 바꾸기', '카메라에 도로 겹쳐 보기', '3D 화면으로 바꾸기'];
const _buttonTips = {
  '차량 모델 가져오기': '모델 가져오기 버튼',
  '장치 연결': '연결 버튼',
  '설정': '설정 버튼',
};
const _reported = '콤마 없음 · 2초 뒤 다시';

ChipState _state(String label) =>
    chipStates.firstWhere((s) => s.label == label);

String _slug(String label) => switch (label) {
  '자동 연결 꺼짐' => 'off',
  '자동 연결 멈춤' => 'paused',
  '콤마 찾는 중 · 1번째' => 'searching_1',
  '콤마 찾는 중 · 240번째' => 'searching_240',
  '콤마 없음 · 2초 뒤 다시' => 'waiting_2s',
  '콤마 없음 · 15초 뒤 다시' => 'waiting_15s',
  '콤마 찾음 · 휴대폰 연결 아직 허용 안 됨' => 'local_only',
  '콤마 2대 찾음' => 'choosing_2',
  '콤마 12대 찾음' => 'choosing_12',
  '콤마 연결됨' => 'connected',
  _ => label.hashCode.toRadixString(16),
};

Future<void> _pumpHome(
  WidgetTester tester,
  Directory root,
  FixedAutoConnect auto,
) async {
  final controller = GatewayController()
    ..scene = DemoDriveScenario(
      route: DemoRoute.city,
    ).sceneAt(const Duration(seconds: 85));
  addTearDown(controller.dispose);
  final settings = SettingsController(
    store: MemorySettingsStore(),
    initial: AppSettings(demoRoute: DemoRoute.city),
  );
  addTearDown(settings.dispose);
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: KovaLinkApp.theme(Brightness.dark),
        builder: (context, child) => RepaintBoundary(key: _key, child: child),
        home: KovaLinkHome(
          controller: controller,
          settings: settings,
          library: VehicleModelLibrary(storageRoot: () async => root),
          autoConnect: auto,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pump();
}

/// Presses the view mode button without hit testing (in old builds the
/// chip lies on top of it).
Future<void> _toCamera(WidgetTester tester) async {
  final button = find.descendant(
    of: find.byTooltip('카메라 화면으로 바꾸기'),
    matching: find.byType(IconButton),
  );
  tester.widget<IconButton>(button).onPressed!();
  await tester.pump();
}

Rect? _rect(WidgetTester tester, Finder f) =>
    f.evaluate().isEmpty ? null : tester.getRect(f.first);

Map<String, Object?> _measure(WidgetTester tester) {
  final parts = <String, Rect>{};
  for (final tip in _modeTips) {
    if (_rect(tester, find.byTooltip(tip)) case final r?) parts['화면 전환 버튼'] = r;
  }
  for (final MapEntry(:key, :value) in _buttonTips.entries) {
    if (_rect(tester, find.byTooltip(key)) case final r?) parts[value] = r;
  }
  if (_rect(tester, _chip) case final r?) parts['연결 상태 칩'] = r;
  if (_rect(tester, find.byKey(const ValueKey('camera-notice')))
      case final r?) {
    parts['카메라 안내'] = r;
  }
  final names = parts.keys.toList();
  final overlaps = <String>[];
  for (var i = 0; i < names.length; i++) {
    for (var j = i + 1; j < names.length; j++) {
      if (parts[names[i]]!.overlaps(parts[names[j]]!)) {
        overlaps.add('${names[i]} ↔ ${names[j]}');
      }
    }
  }
  final chip = parts['연결 상태 칩'];
  final settings = parts['설정 버튼'];
  var cut = false;
  for (final e
      in find
          .descendant(of: _chip, matching: find.byType(RichText))
          .evaluate()) {
    final render = e.renderObject;
    if (render is RenderParagraph && render.didExceedMaxLines) cut = true;
  }
  return {
    'parts': {
      for (final MapEntry(:key, :value) in parts.entries)
        key: [
          value.left,
          value.top,
          value.width,
          value.height,
        ].map((v) => double.parse(v.toStringAsFixed(1))).toList(),
    },
    'overlaps': overlaps,
    'chipRow': chip == null || settings == null
        ? null
        : chip.bottom <= settings.top
        ? 'own row'
        : 'button row',
    'chipCut': cut,
  };
}

class _Shot {
  const _Shot(this.device, this.scale);
  final DeviceProfile device;
  final double scale;
  String get id =>
      scale == 1 ? device.id : '${device.id}_text${(scale * 100).round()}';
}

final _results = <String, Object>{};

void main() {
  final before = Platform.environment['KOVA_BEFORE_DIR'];
  final sheets = Platform.environment['KOVA_SHEETS'] != '0';

  tearDownAll(() {
    final file = File('$shotDirectory/report.json');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(_results),
    );
  });

  final shots = [
    for (final d in [reportedPhone, ...allDevices]) _Shot(d, 1),
    for (final d in [
      reportedPhone,
      portraitDevices.first,
      portraitDevices[2],
      portraitDevices[4],
      landscapeDevices[2],
    ])
      _Shot(d, 1.3),
  ];

  for (final shot in shots) {
    final device = shot.device;
    testWidgets('capture ${shot.id}', (tester) async {
      await tester.runAsync(loadReviewFonts);
      device.apply(tester);
      addTearDown(tester.view.reset);
      if (shot.scale != 1) {
        tester.platformDispatcher.textScaleFactorTestValue = shot.scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('kl_barshot_'),
      ))!;
      final pixelRatio = math.min(device.dpr, 2.0);
      final auto = FixedAutoConnect(_state(_reported));
      final perShot = <String, Object>{};
      // Every wording on the 16:39 phone; the reported and the longest
      // one elsewhere.
      final labels = device == reportedPhone && shot.scale == 1
          ? [for (final s in chipStates) s.label]
          : [_reported, longestChipState.label];
      await _pumpHome(tester, root, auto);
      for (final camera in [false, true]) {
        if (camera) await _toCamera(tester);
        for (final label in labels) {
          auto.show(_state(label));
          await tester.pump();
          final name = '${camera ? 'camera' : '3d'}_${_slug(label)}';
          perShot[name] = {'label': label, ..._measure(tester)};
          await saveBoundary(
            tester,
            _key,
            '${shot.id}/$name',
            pixelRatio: pixelRatio,
          );
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      auto.dispose();
      await tester.runAsync(() => root.delete(recursive: true));
      _results[shot.id] = {
        'label': device.label,
        'size': device.sizeLabel,
        'textScale': shot.scale,
        'padding': [
          device.padding.left,
          device.padding.top,
          device.padding.right,
          device.padding.bottom,
        ],
        'shots': perShot,
      };
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  if (!sheets) return;
  testWidgets('sheets', (tester) async {
    await tester.runAsync(() async {
      await loadReviewFonts();
      final out = '$shotDirectory/sheets';
      String path(String dir, String id, String name) => '$dir/$id/$name.png';
      final beforeFile = File('$before/report.json');
      final beforeResults = before != null && beforeFile.existsSync()
          ? jsonDecode(beforeFile.readAsStringSync()) as Map<String, dynamic>
          : <String, dynamic>{};
      List<String> problems(String id, String name, {bool old = false}) {
        final results = old ? beforeResults : _results;
        final shots =
            (results[id] as Map?)?['shots'] as Map<String, dynamic>? ?? {};
        final r = shots[name] as Map<String, dynamic>?;
        if (r == null) return const [];
        return [
          for (final o in r['overlaps'] as List) '겹침 $o',
          if (r['chipCut'] == true) '말줄임',
        ];
      }

      String note(String id, String name, {bool old = false}) {
        final p = problems(id, name, old: old);
        final results = old ? beforeResults : _results;
        final shots =
            (results[id] as Map?)?['shots'] as Map<String, dynamic>? ?? {};
        final row = (shots[name] as Map?)?['chipRow'];
        final where = row == 'own row' ? '칩 윗줄' : '칩 버튼 줄';
        return p.isEmpty ? '$where · 겹침 없음' : '$where · ${p.join(', ')}';
      }

      // 1. The 16:39 phone, before and after, as in the screenshot.
      if (before != null) {
        final cells = <_Cell>[];
        for (final name in ['camera_waiting_2s', '3d_waiting_2s']) {
          final b = path(before, reportedPhone.id, name);
          if (File(b).existsSync()) {
            cells.add(
              _Cell(
                b,
                '전 · ${name.startsWith('camera') ? '카메라' : '3D'}',
                note(reportedPhone.id, name, old: true),
                warn: true,
              ),
            );
          }
          cells.add(
            _Cell(
              path(shotDirectory, reportedPhone.id, name),
              '후 · ${name.startsWith('camera') ? '카메라' : '3D'}',
              note(reportedPhone.id, name),
            ),
          );
        }
        await _sheet(
          out,
          'reported_phone_before_after',
          '16:39 실기기 크기 (${reportedPhone.sizeLabel}) — 하단 칩 전·후',
          cells,
          cellHeight: 1100,
        );
      }

      // 2. Bottom of the 16:39 phone in every wording (crop).
      final crop = Rect.fromLTWH(
        0,
        (reportedPhone.height - 190) * 2,
        reportedPhone.width * 2,
        190 * 2,
      );
      final wordings = <_Cell>[];
      for (final s in chipStates) {
        final name = 'camera_${_slug(s.label)}';
        if (before != null &&
            File(path(before, reportedPhone.id, name)).existsSync()) {
          wordings.add(
            _Cell(
              path(before, reportedPhone.id, name),
              '전 · ${s.label}',
              note(reportedPhone.id, name, old: true),
              warn: true,
              crop: crop,
              height: 380,
            ),
          );
        }
        wordings.add(
          _Cell(
            path(shotDirectory, reportedPhone.id, name),
            '후 · ${s.label}',
            note(reportedPhone.id, name),
            crop: crop,
            height: 380,
          ),
        );
      }
      await _sheet(
        out,
        'reported_phone_all_wordings',
        '16:39 실기기 크기 — 칩 문구 ${chipStates.length}가지 (하단만)',
        wordings,
        cellHeight: 380,
        maxWidth: before != null ? 1700 : 3800,
      );

      // 3. Every device, the reported wording and the longest one.
      for (final (label, slug) in [
        (_reported, 'waiting_2s'),
        (longestChipState.label, 'local_only'),
      ]) {
        final cells = <_Cell>[];
        for (final s in shots) {
          final name = 'camera_$slug';
          final p = path(shotDirectory, s.id, name);
          if (!File(p).existsSync()) continue;
          cells.add(
            _Cell(
              p,
              '${s.device.label}${s.scale == 1 ? '' : ' · 글자 130%'}',
              '${s.device.sizeLabel} · ${note(s.id, name)}',
              warn: problems(s.id, name).isNotEmpty,
            ),
          );
        }
        await _sheet(
          out,
          'devices_$slug',
          '기기 모음 — "$label" (카메라 화면)',
          cells,
          cellHeight: 600,
        );
      }
    });
  }, timeout: const Timeout(Duration(minutes: 10)));
}

class _Cell {
  _Cell(
    this.path,
    this.title,
    this.subtitle, {
    this.warn = false,
    this.crop,
    this.height,
  });
  final String path;
  final String title;
  final String subtitle;
  final bool warn;
  final Rect? crop;
  final double? height;
}

const _gap = 24.0;
const _labelHeight = 78.0;

Future<ui.Image> _load(String path) async {
  final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
  return (await codec.getNextFrame()).image;
}

void _text(
  Canvas canvas,
  String text,
  Offset at,
  double size,
  Color color,
  double maxWidth, {
  FontWeight weight = FontWeight.w600,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: 'Roboto',
        fontSize: size,
        color: color,
        fontWeight: weight,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: math.max(10, maxWidth));
  painter.paint(canvas, at);
}

/// Cells scaled to their height, wrapped into rows no wider than
/// [maxWidth]; saved as JPG.
Future<void> _sheet(
  String outDir,
  String name,
  String title,
  List<_Cell> cells, {
  double cellHeight = 900,
  double maxWidth = 3800,
}) async {
  if (cells.isEmpty) return;
  final images = [for (final c in cells) await _load(c.path)];
  Rect src(int i) {
    final full =
        Offset.zero &
        Size(images[i].width.toDouble(), images[i].height.toDouble());
    return cells[i].crop?.intersect(full) ?? full;
  }

  double h(int i) => cells[i].height ?? cellHeight;
  final widths = [
    for (var i = 0; i < cells.length; i++) src(i).width * h(i) / src(i).height,
  ];
  final rows = <List<int>>[[]];
  var x = _gap;
  for (var i = 0; i < cells.length; i++) {
    if (rows.last.isNotEmpty && x + widths[i] + _gap > maxWidth) {
      rows.add([]);
      x = _gap;
    }
    rows.last.add(i);
    x += widths[i] + _gap;
  }
  final rowWidths = [
    for (final r in rows) r.fold(_gap, (a, i) => a + widths[i] + _gap),
  ];
  final width = math.max(rowWidths.reduce(math.max), 1400.0);
  final rowHeights = [for (final r in rows) r.map(h).reduce(math.max)];
  const header = 110.0;
  final height =
      header +
      rowHeights.fold(0.0, (a, rh) => a + rh + _labelHeight + _gap) +
      _gap;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFF1B1F24),
  );
  _text(
    canvas,
    title,
    const Offset(_gap, 28),
    44,
    Colors.white,
    width - 48,
    weight: FontWeight.w800,
  );
  var y = header;
  for (final (row, r) in rows.indexed) {
    var cx = _gap;
    for (final i in r) {
      final c = cells[i];
      _text(
        canvas,
        c.title,
        Offset(cx, y),
        30,
        Colors.white,
        widths[i],
        weight: FontWeight.w700,
      );
      _text(
        canvas,
        c.subtitle,
        Offset(cx, y + 38),
        24,
        c.warn ? const Color(0xFFFFB454) : const Color(0xFF9FB0BF),
        widths[i],
      );
      final dst = Rect.fromLTWH(cx, y + _labelHeight, widths[i], h(i));
      canvas.drawImageRect(
        images[i],
        src(i),
        dst,
        Paint()..filterQuality = FilterQuality.high,
      );
      canvas.drawRect(
        dst,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = c.warn ? const Color(0xFFFFB454) : const Color(0xFF3A444F),
      );
      cx += widths[i] + _gap;
    }
    y += rowHeights[row] + _labelHeight + _gap;
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width.round(), height.round());
  final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final out = img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: raw!.buffer,
    numChannels: 4,
  );
  var quality = 88;
  var bytes = img.encodeJpg(out, quality: quality);
  while (bytes.length > 7.5 * 1024 * 1024 && quality > 50) {
    quality -= 8;
    bytes = img.encodeJpg(out, quality: quality);
  }
  final file = File('$outDir/$name.jpg');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}
