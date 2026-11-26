// Review captures of 콤마 다시 켜기 on 설정 → kovapilot → kovapilot 버전 (not
// part of `flutter test`'s test/ directory).
//
//   KOVA_SHOT_DIR=out flutter test tool/screenshots/kovapilot_restart_capture_test.dart
//
// One PNG per state: a staged update with 지금 다시 켜기, the confirm
// dialog, restarting, back on the new commit, not back, and the status card
// button off while the car is on.
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

final _phone = portraitDevices.firstWhere((d) => d.id == 'phone_412x915');

final Finder _page = find
    .byWidgetPredicate(
      (w) =>
          w is Scrollable &&
          axisDirectionToAxis(w.axisDirection) == Axis.vertical,
    )
    .first;

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _capture(
  WidgetTester tester,
  String name, {
  void Function(FakeKovaGitGateway gateway)? setup,
  Future<void> Function(WidgetTester tester, KovaGitController controller)? act,
  bool top = true,
}) async {
  _phone.apply(tester);
  final gateway = FakeKovaGitGateway.sample()
    ..applyEnabled = true
    ..restartEnabled = true;
  setup?.call(gateway);
  final controller = KovaGitController(
    clientFactory: (e) => KovaGitClient.tryCreate(e, transport: gateway),
    followInterval: const Duration(seconds: 3),
    restartTimeout: name.contains('not_back')
        ? const Duration(seconds: 9)
        : const Duration(minutes: 4),
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
  await act?.call(tester, controller);
  await _frames(tester);
  if (top) {
    tester.state<ScrollableState>(_page).position.jumpTo(0);
    await _frames(tester);
  }
  await saveBoundary(tester, key, name, pixelRatio: _phone.dpr);
  await tester.pumpWidget(const SizedBox());
  controller.dispose();
  tester.view.reset();
}

Map<String, Object?> _staged(FakeKovaGitGateway g) => {
  'operation': 'switch',
  'branch': _shadow,
  'commit': g.commitOf(_shadow).sha,
  'phase': 'staged',
};

Future<void> _confirm(WidgetTester tester, String button) async {
  final target = find.byKey(ValueKey(button));
  await tester.ensureVisible(target);
  await _frames(tester);
  await tester.tap(target);
  await _frames(tester);
  await tester.tap(find.byKey(const ValueKey('git-restart-confirm')));
  await _frames(tester);
}

void main() {
  testWidgets('kovapilot restart captures', (tester) async {
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

    await _capture(
      tester,
      'restart_1_staged',
      setup: (g) => g.maintenance = _staged(g),
    );

    await _capture(
      tester,
      'restart_2_confirm',
      top: false,
      setup: (g) => g.maintenance = _staged(g),
      act: (tester, _) async {
        await tester.tap(find.byKey(const ValueKey('git-restart-staged')));
      },
    );

    await _capture(
      tester,
      'restart_3_restarting',
      setup: (g) => g.maintenance = _staged(g),
      act: (tester, _) => _confirm(tester, 'git-restart-staged'),
    );

    await _capture(
      tester,
      'restart_4_back',
      setup: (g) => g.maintenance = _staged(g),
      act: (tester, _) async {
        await _confirm(tester, 'git-restart-staged');
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(seconds: 3));
        }
      },
    );

    await _capture(
      tester,
      'restart_5_not_back',
      setup: (g) => g.restartDownRequests = 1000,
      act: (tester, _) async {
        await _confirm(tester, 'git-restart');
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(seconds: 3));
        }
        await tester.pumpAndSettle();
        await tester.fling(_page, const Offset(0, 2000), 3000);
        await tester.pumpAndSettle();
      },
    );

    await _capture(
      tester,
      'restart_6_car_on',
      top: false,
      setup: (g) => g.restartEnabled = false,
      act: (tester, _) async {
        await tester.ensureVisible(find.byKey(const ValueKey('git-restart')));
      },
    );
  });
}
