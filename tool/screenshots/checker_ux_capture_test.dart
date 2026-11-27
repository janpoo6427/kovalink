// Same-size captures of the settings screen for before/after review. The
// file is self-contained so it also runs on older commits.
//
//   KOVA_SHOT_DIR=out flutter test tool/screenshots/settings_compare_capture_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';

import 'shot_support.dart' show loadReviewFonts, shotDirectory;

const _ratio = 2.625;

Future<void> _save(WidgetTester tester, GlobalKey key, String name) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: _ratio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$shotDirectory/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  for (final (name, height, scrollToEnd) in [
    ('settings_phone_dark', 2340.0, false),
    ('settings_phone_light', 2340.0, false),
  ]) {
    testWidgets('capture $name', (tester) async {
      await tester.runAsync(loadReviewFonts);
      tester.view.physicalSize = Size(1080, height);
      tester.view.devicePixelRatio = _ratio;
      addTearDown(tester.view.reset);
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('kl_cmp_'),
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
              theme: KovaLinkApp.theme(
                name.endsWith('light') ? Brightness.light : Brightness.dark,
              ),
              home: KovaPage(
                title: '설정',
                child: SettingsScreen(
                  controller: controller,
                  settings: settings,
                  library: library,
                ),
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();
      if (scrollToEnd) {
        for (var i = 0; i < 12; i++) {
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -800),
          );
          await tester.pump();
        }
      }
      expect(tester.takeException(), isNull);
      await _save(tester, key, name);
      await tester.tap(find.byKey(const ValueKey('setting-viewpoint')));
      await tester.pumpAndSettle();
      await _save(tester, key, '${name}_choices');
      await tester.tap(find.text('상단'));
      await tester.pumpAndSettle();
      expect(settings.value.viewpoint.name, 'topDown');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.runAsync(() => root!.delete(recursive: true));
    });
  }
}
