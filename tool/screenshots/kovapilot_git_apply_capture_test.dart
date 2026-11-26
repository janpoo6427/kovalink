// Review captures of 적용 on 설정 → kovapilot → kovapilot 버전 (not part of
// `flutter test`'s test/ directory).
//
//   KOVA_SHOT_DIR=out flutter test tool/screenshots/kovapilot_git_apply_capture_test.dart
//
// One PNG per state: a switch preview with 적용 on, the download in
// progress, staged (restart the comma), installed, a failed download, and
// 적용 off while the car is on. Data comes from the in-memory gateway in
// test/support/fake_kova_git_gateway.dart.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/features/kovapilot_git/kovapilot_version_screen.dart';
import 'package:kovalink/src/kovapilot_git/git_client.dart';
import 'package:kovalink/src/kovapilot_git/git_controller.dart';

import '../../test/support/device_profiles.dart';
import '../../test/support/fake_kova_git_gateway.dart';
import 'shot_support.dart';

const _endpoint = 'http://192.168.0.40:8082';
const _shadow = 'feature/longitudinal-shadow';

final Finder _page = find
    .byWidgetPredicate(
      (w) =>
          w is Scrollable &&
          axisDirectionToAxis(w.axisDirection) == Axis.vertical,
    )
    .first;

final _phone = portraitDevices.firstWhere((d) => d.id == 'phone_412x915');

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _capture(
  WidgetTester tester,
  String name, {
  void Function(FakeKovaGitGateway gateway)? setup,
  Future<void> Function(WidgetTester tester, FakeKovaGitGateway gateway)? act,
}) async {
  _phone.apply(tester);
  final gateway = FakeKovaGitGateway.sample()..applyEnabled = true;
  setup?.call(gateway);
  final controller = KovaGitController(
    clientFactory: (e) => KovaGitClient.tryCreate(e, transport: gateway),
    followInterval: const Duration(hours: 1),
  );
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: KovaLinkApp.theme(Brightness.dark),
        home: KovaPage(
          title: "kovapilot 버전",
          backTooltip: KovaRoutes.backToSettings,
          child: KovapilotVersionScreen(
            endpoint: _endpoint,
            controller: controller,
            now: DateTime(2026, 11, 26, 16),
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
  await act?.call(tester, gateway);
  await _frames(tester);
  await saveBoundary(tester, key, name, pixelRatio: _phone.dpr);
  await tester.pumpWidget(const SizedBox());
  controller.dispose();
  tester.view.reset();
}

Map<String, Object?> _entry(FakeKovaGitGateway g, String phase) => {
  'operation': 'switch',
  'branch': _shadow,
  'commit': g.commitOf(_shadow).sha,
  'phase': phase,
  if (phase == 'failed') 'reason': 'stagingFailed',
};

void main() {
  testWidgets('kovapilot apply captures', (tester) async {
    await tester.runAsync(() async {
      await loadReviewFonts();
      const mono = '/usr/share/fonts/dejavu-sans-mono-fonts';
      final loader = FontLoader('monospace');
      for (final file in ['DejaVuSansMono.ttf', 'DejaVuSansMono-Bold.ttf']) {
        final f = File('$mono/$file');
        if (f.existsSync()) {
          loader.addFont(
            Future.value(ByteData.sublistView(f.readAsBytesSync())),
          );
        }
      }
      await loader.load();
    });

    await _capture(tester, 'apply_1_ready');

    await _capture(
      tester,
      'apply_2_preview_on',
      act: (tester, _) async {
        final tile = find.byKey(const ValueKey('git-branch-$_shadow'));
        await tester.scrollUntilVisible(tile, 200, scrollable: _page);
        await _frames(tester);
        await tester.tap(tile);
      },
    );

    await _capture(
      tester,
      'apply_3_downloading',
      setup: (g) {
        g.maintenance = _entry(g, 'queued');
        g.updaterState = 'downloading...';
      },
    );

    await _capture(
      tester,
      'apply_4_staged',
      setup: (g) => g.maintenance = _entry(g, 'staged'),
    );

    await _capture(
      tester,
      'apply_5_installed',
      setup: (g) {
        g.maintenance = _entry(g, 'staged');
        g.install();
      },
    );

    await _capture(
      tester,
      'apply_6_failed',
      setup: (g) => g.maintenance = _entry(g, 'failed'),
    );

    await _capture(
      tester,
      'apply_7_car_on',
      setup: (g) => g
        ..applyEnabled = false
        ..mutationBlock = 'offroadOrUpdaterBusy',
      act: (tester, _) async {
        final tile = find.byKey(const ValueKey('git-branch-$_shadow'));
        await tester.scrollUntilVisible(tile, 200, scrollable: _page);
        await _frames(tester);
        await tester.tap(tile);
      },
    );
  });
}
