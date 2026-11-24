// Headless screen capture for review (not part of `flutter test`'s default
// test/ directory). Writes PNGs to $KOVA_SHOT_DIR (default build/shots).
//
//   KOVA_SHOT_DIR=/path flutter test tool/screenshots
//
// Fonts: loads Noto Sans CJK KR from the host if present so Korean text
// renders; otherwise the test font (boxes) is used.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String get shotDirectory =>
    Platform.environment['KOVA_SHOT_DIR'] ?? 'build/shots';

Future<void> loadReviewFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    var any = false;
    for (final path in paths) {
      final file = File(path);
      if (file.existsSync()) {
        loader.addFont(
          Future.value(ByteData.sublistView(file.readAsBytesSync())),
        );
        any = true;
      }
    }
    if (any) await loader.load();
  }

  const cjk = '/usr/share/fonts/google-noto-cjk';
  const cjkFiles = [
    '$cjk/NotoSansCJKkr-Regular.otf',
    '$cjk/NotoSansCJKkr-Medium.otf',
    '$cjk/NotoSansCJKkr-Bold.otf',
    '$cjk/NotoSansCJKkr-Black.otf',
  ];
  // Widgets use Roboto by default; bare TextPainters in tests use the
  // FlutterTest family.
  await load('Roboto', cjkFiles);
  await load('FlutterTest', cjkFiles);
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ??
      File(
        Platform.resolvedExecutable,
      ).parent.parent.parent.parent.parent.parent.path;
  await load('MaterialIcons', [
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

Future<void> saveBoundary(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$shotDirectory/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> savePainter(CustomPainter painter, Size size, String name) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final image = await recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('$shotDirectory/$name.png');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes!.buffer.asUint8List());
}
