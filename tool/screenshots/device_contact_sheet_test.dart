// Contact sheets from the device matrix captures: one JPG per comparison
// with each cell labelled by device, size and the layout findings from
// report.json. Run after device_matrix_capture_test.dart.
//
//   KOVA_SHOT_DIR=out flutter test tool/screenshots/device_contact_sheet_test.dart
//   KOVA_SHEET_DIR=dir      output (default $KOVA_SHOT_DIR/sheets)
//   KOVA_BEFORE_DIR=dir     captures of the baseline build: adds
//                           before/after sheets
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'shot_support.dart';

class _Cell {
  _Cell(
    this.path,
    this.title,
    this.subtitle, {
    this.warn = false,
    this.crop,
    this.marks = const [],
    this.height,
  });
  final String path;
  final String title;
  final String subtitle;
  final bool warn;

  /// Part of the capture to show, in capture pixels (null: all of it).
  final Rect? crop;

  /// Vertical guide lines (x in capture pixels), e.g. where the blinkers
  /// sit after the fix.
  final List<double> marks;

  /// Cell height on the sheet (null: the sheet's height).
  final double? height;
}

const _maxWidth = 3800.0;
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
  )..layout(maxWidth: maxWidth);
  painter.paint(canvas, at);
}

/// Cells scaled to their height (default [cellHeight]), wrapped into rows
/// no wider than [_maxWidth].
Future<void> _sheet(
  String outDir,
  String name,
  String title,
  List<_Cell> cells, {
  double cellHeight = 900,
}) async {
  final images = <ui.Image>[];
  for (final c in cells) {
    images.add(await _load(c.path));
  }
  Rect src(int i) =>
      cells[i].crop ??
      Offset.zero &
          Size(images[i].width.toDouble(), images[i].height.toDouble());
  double h(int i) => cells[i].height ?? cellHeight;
  final widths = [
    for (var i = 0; i < cells.length; i++) src(i).width * h(i) / src(i).height,
  ];
  // Very wide cells (landscape tablets) would make a single huge row.
  final rows = <List<int>>[[]];
  var x = _gap;
  for (var i = 0; i < cells.length; i++) {
    if (rows.last.isNotEmpty && x + widths[i] + _gap > _maxWidth) {
      rows.add([]);
      x = _gap;
    }
    rows.last.add(i);
    x += widths[i] + _gap;
  }
  final rowWidths = [
    for (final r in rows) r.fold(_gap, (a, i) => a + widths[i] + _gap),
  ];
  final width = rowWidths.reduce(math.max);
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
      for (final x in c.marks) {
        final dx = dst.left + (x - src(i).left) * dst.width / src(i).width;
        canvas.drawLine(
          Offset(dx, dst.top),
          Offset(dx, dst.bottom),
          Paint()
            ..color = const Color(0xCCFF4FA3)
            ..strokeWidth = 3,
        );
      }
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

const _screenNames = {
  'drive_city': '주행 화면 (시내)',
  'drive_city_nolight': '주행 화면 (신호등 없음)',
  'drive_camera': '카메라 화면 (카메라 없음)',
  'drive_highway': '주행 화면 (고속도로)',
  'connect': '장치 연결',
  'settings_app': '설정 · 앱',
  'settings_session': '설정 · 연결 상태',
  'settings_kovapilot': '설정 · kovapilot',
};

void main() {
  testWidgets('device contact sheets', (tester) async {
    await tester.runAsync(loadReviewFonts);
    final dir = shotDirectory;
    final outDir = Platform.environment['KOVA_SHEET_DIR'] ?? '$dir/sheets';
    final before = Platform.environment['KOVA_BEFORE_DIR'];
    final report =
        jsonDecode(File('$dir/report.json').readAsStringSync())
            as Map<String, dynamic>;
    Map<String, dynamic>? beforeReport;
    if (before != null && File('$before/report.json').existsSync()) {
      beforeReport =
          jsonDecode(File('$before/report.json').readAsStringSync())
              as Map<String, dynamic>;
    }

    String findings(Map<String, dynamic>? device, String screen) {
      final s =
          (device?['screens'] as Map<String, dynamic>?)?[screen]
              as Map<String, dynamic>?;
      if (s == null) return '';
      final parts = <String>[];
      void count(String key, String label) {
        final n = (s[key] as List).length;
        if (n > 0) parts.add('$label $n');
      }

      count('errors', '오류');
      count('offscreen', '화면 밖');
      count('unsafe', '안전영역');
      count('overlaps', '겹침');
      if (s['navZone'] != null) count('navZone', '내비 자리');
      count('clippedText', '글자 잘림');
      if (s['wrappedLabels'] != null) count('wrappedLabels', '버튼 글자 줄바꿈');
      return parts.isEmpty ? '문제 없음' : parts.join(' · ');
    }

    _Cell cell(
      String id,
      String screen, {
      String? root,
      String? prefix,
      String? screenName,
      bool withScreen = true,
      double? portraitHeight,
      double? landscapeHeight,
    }) {
      final rep = root != null && root == before ? beforeReport : report;
      final d = rep?[id] as Map<String, dynamic>?;
      final f = findings(d, screen);
      final scale = (d?['textScale'] as num?) ?? 1;
      final name = screenName ?? _screenNames[screen] ?? screen;
      return _Cell(
        '${root ?? dir}/$id/$screen.png',
        '${prefix ?? ''}${d?['label'] ?? id}${scale == 1 ? '' : ' · 글자 ${(scale * 100).round()}%'}'
            '${withScreen ? ' · $name' : ''}',
        '${d?['size'] ?? ''}  ·  $f',
        warn: f != '문제 없음',
        height: (report[id] as Map<String, dynamic>?)?['landscape'] == true
            ? landscapeHeight
            : portraitHeight,
      );
    }

    List<String> ids(bool Function(Map<String, dynamic>) test) => [
      for (final e in report.entries)
        if (test(e.value as Map<String, dynamic>)) e.key,
    ];
    final portrait = ids((d) => d['landscape'] == false && d['textScale'] == 1);
    final landscape = ids((d) => d['landscape'] == true && d['textScale'] == 1);
    final phones = portrait
        .where((id) => (report[id] as Map)['group'] != 'tablet')
        .toList();
    final tablets = portrait
        .where((id) => (report[id] as Map)['group'] == 'tablet')
        .toList();
    final big = ids((d) => d['textScale'] != 1);

    /// Capture pixels per logical pixel for a device's captures.
    double scaleOf(Map<String, dynamic>? rep, String id) {
      final dpr = (rep?[id] as Map<String, dynamic>?)?['dpr'] as num?;
      return math.min((dpr ?? 2).toDouble(), 2);
    }

    /// Logical rect of a HUD part recorded in report.json.
    Rect? partOf(
      Map<String, dynamic>? rep,
      String id,
      String screen,
      String name,
    ) {
      final parts =
          ((rep?[id] as Map<String, dynamic>?)?['screens']
                  as Map<String, dynamic>?)?[screen]?['parts']
              as List?;
      for (final p in parts ?? const []) {
        final m = RegExp(
          '^$name \\((-?\\d+),(-?\\d+) (\\d+)×(\\d+)\\)\$',
        ).firstMatch(p as String);
        if (m != null) {
          final v = [for (var g = 1; g <= 4; g++) double.parse(m.group(g)!)];
          return Rect.fromLTWH(v[0], v[1], v[2], v[3]);
        }
      }
      return null;
    }

    /// Band around the blinker row, the full width of the screen.
    _Cell blinkerCell(
      String id,
      String screen, {
      String? root,
      String? prefix,
    }) {
      final rep = root != null && root == before ? beforeReport : report;
      final base = cell(
        id,
        screen,
        root: root,
        prefix: prefix,
        screenName: screen == 'drive_city' ? '신호등 있음' : '신호등 없음',
      );
      final row = partOf(rep, id, screen, '신호 알약');
      final s = scaleOf(report, id);
      final width = ((report[id] as Map<String, dynamic>)['width'] as num)
          .toDouble();
      final crop = row == null
          ? null
          : Rect.fromLTRB(
              0,
              (row.top - 30) * s,
              width * s,
              (row.bottom + 30) * s,
            );
      // Guide lines: where the blinkers sit after the fix.
      final after = partOf(report, id, screen, '신호 알약');
      return _Cell(
        base.path,
        base.title,
        base.subtitle,
        warn: base.warn,
        crop: crop,
        marks: after == null
            ? const []
            : [(after.left + 22) * s, (after.right - 22) * s],
      );
    }

    await tester.runAsync(() async {
      final everyDevice = [
        for (final e in report.entries)
          if ((e.value as Map<String, dynamic>)['textScale'] == 1) e.key,
      ];
      await _sheet(
        outDir,
        '00_all_devices',
        '모든 기기 한눈에 — 주행 화면 (시내) · 세로 ${portrait.length}종 · 가로 ${landscape.length}종',
        [
          for (final id in everyDevice)
            cell(
              id,
              'drive_city',
              withScreen: false,
              portraitHeight: 820,
              landscapeHeight: 470,
            ),
        ],
      );
      await _sheet(
        outDir,
        '01_phones_portrait_drive',
        '폰 · 폴드 세로 — 주행 화면 (시내, HUD 최다)',
        [for (final id in phones) cell(id, 'drive_city')],
        cellHeight: 1100,
      );
      await _sheet(outDir, '02_tablets_portrait_drive', '태블릿 세로 — 주행 화면 (시내)', [
        for (final id in tablets) cell(id, 'drive_city'),
      ], cellHeight: 1100);
      await _sheet(
        outDir,
        '03_landscape_drive',
        '가로 (차량 거치 폰 · 태블릿) — 주행 화면 (시내)',
        [for (final id in landscape) cell(id, 'drive_city')],
        cellHeight: 620,
      );
      await _sheet(outDir, '04_settings_portrait', '세로 — 설정 · 앱 탭', [
        for (final id in portrait) cell(id, 'settings_app'),
      ], cellHeight: 1000);
      await _sheet(
        outDir,
        '05_landscape_settings_connect',
        '가로 — 설정 · 앱 / 장치 연결',
        [
          for (final id in landscape) cell(id, 'settings_app'),
          for (final id in landscape) cell(id, 'connect'),
        ],
        cellHeight: 560,
      );
      await _sheet(
        outDir,
        '06_connect_kovapilot_portrait',
        '세로 — 장치 연결 · 설정 kovapilot · 연결 상태',
        [
          for (final id in [
            portrait.first,
            portrait[2],
            tablets.first,
            tablets.last,
          ])
            cell(id, 'connect'),
          for (final id in [
            portrait.first,
            portrait[2],
            tablets.first,
            tablets.last,
          ])
            cell(id, 'settings_kovapilot'),
          for (final id in [portrait.first, tablets.last])
            cell(id, 'settings_session'),
        ],
        cellHeight: 1000,
      );
      await _sheet(outDir, '07_text_scale_130', '글자 크기 130% (접근성)', [
        for (final id in big) ...[
          cell(id, 'drive_city'),
          cell(id, 'settings_app'),
          cell(id, 'connect'),
        ],
      ], cellHeight: 1000);
      await _sheet(outDir, '08_highway_drive', '주행 화면 (고속도로) — 모든 기기', [
        for (final id in [...portrait, ...landscape]) cell(id, 'drive_highway'),
      ], cellHeight: 700);
      await _sheet(
        outDir,
        '12_camera_notice_all',
        '카메라 화면 (카메라 없음) — 안내 카드 위치 · 주황 점선 = 내비 오버레이 자리 (캡처 표시)',
        [
          for (final id in everyDevice)
            cell(
              id,
              'drive_camera',
              withScreen: false,
              portraitHeight: 820,
              landscapeHeight: 470,
            ),
        ],
      );
      if (before != null) {
        final blinkerIds =
            (Platform.environment['KOVA_BLINKER_DEVICES'] ??
                    'phone_393x852,phone_852x393,tablet_834x1194')
                .split(',');
        await _sheet(
          outDir,
          '10_blinkers_before_after',
          '방향지시등 — 신호등 없음 / 있음, 고치기 전 → 고친 뒤 (분홍 선 = 고친 뒤 화살표 자리)',
          [
            for (final id in blinkerIds) ...[
              blinkerCell(
                id,
                'drive_city_nolight',
                root: before,
                prefix: '전 · ',
              ),
              blinkerCell(id, 'drive_city', root: before, prefix: '전 · '),
              blinkerCell(id, 'drive_city_nolight', prefix: '후 · '),
              blinkerCell(id, 'drive_city', prefix: '후 · '),
            ],
          ],
          cellHeight: 170,
        );
        await _sheet(
          outDir,
          '11_camera_notice_before_after',
          '카메라 안내 카드 — 고치기 전 → 고친 뒤 (주황 점선 = 내비 오버레이 자리, 캡처 표시)',
          [
            for (final id
                in (Platform.environment['KOVA_CAMERA_DEVICES'] ??
                        'phone_360x640,phone_393x852,phone_852x393,tablet_1194x834')
                    .split(',')) ...[
              cell(
                id,
                'drive_camera',
                root: before,
                prefix: '전 · ',
                portraitHeight: 1000,
                landscapeHeight: 560,
              ),
              cell(
                id,
                'drive_camera',
                prefix: '후 · ',
                portraitHeight: 1000,
                landscapeHeight: 560,
              ),
            ],
          ],
          cellHeight: 900,
        );
        final pairs =
            (Platform.environment['KOVA_COMPARE'] ??
                    'phone_393x852:drive_city,phone_852x393:drive_city,'
                        'phone_915x412:drive_city,tablet_1366x1024:settings_app,'
                        'phone_360x640:connect')
                .split(',');
        await _sheet(outDir, '09_before_after', '고치기 전 → 고친 뒤', [
          for (final pair in pairs) ...[
            cell(
              pair.split(':')[0],
              pair.split(':')[1],
              root: before,
              prefix: '전 · ',
            ),
            cell(pair.split(':')[0], pair.split(':')[1], prefix: '후 · '),
          ],
        ], cellHeight: 820);
      }
    });
  }, timeout: const Timeout(Duration(minutes: 10)));
}
