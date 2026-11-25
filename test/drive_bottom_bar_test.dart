// The drive screen's bottom bar: the view mode button, the 자동 연결 chip
// and the round buttons never cover each other (2026-11-25 16:39 phone:
// "콤마 없음 · 2초 뒤 다시" ran under the mode button), in every chip
// wording, on every device in portrait and landscape, at 100 % and 130 %
// text, in the 3D and the camera view (with its notice card). Buttons and
// the chip keep the 48 dp touch target; the chip does not change rows as
// its wording changes.
//
// Text widths matter here, so the real Korean font (Noto Sans CJK KR, on
// the worker) is loaded; without it the device checks are skipped.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/app/kovalink_home.dart';
import 'package:kovalink/src/features/connect/auto_connect_panel.dart';
import 'package:kovalink/src/features/road_view/drive_bottom_bar.dart';
import 'package:kovalink/src/features/road_view/hud/drive_hud.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';

import '../tool/screenshots/shot_support.dart';
import 'support/device_profiles.dart';
import 'support/drive_bar_fixtures.dart';
import 'support/fake_auto_connect.dart';
import 'support/layout_probe.dart';

final _realFonts = File(
  '/usr/share/fonts/google-noto-cjk/NotoSansCJKkr-Regular.otf',
).existsSync();

/// Same wording with every number as `#`.
String _shape(String label) => label.replaceAll(RegExp(r'\d+'), '#');

const _modeTips = ['카메라 화면으로 바꾸기', '카메라에 도로 겹쳐 보기', '3D 화면으로 바꾸기'];
const _buttonTips = ['차량 모델 가져오기', '장치 연결', '설정'];

/// The bar's parts, as the shared drive screen check names them.
const _barParts = ['화면 전환 버튼', '모델 가져오기 버튼', '연결 버튼', '설정 버튼', '연결 상태 칩'];
final _chip = find.byKey(const ValueKey('auto-connect-chip'));

Future<void> _pumpHome(
  WidgetTester tester,
  Directory root,
  AutoConnectController auto,
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
        theme: KovaLinkApp.theme(Brightness.dark),
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

Rect _modeButton(WidgetTester tester) {
  for (final tip in _modeTips) {
    final f = find.byTooltip(tip);
    if (f.evaluate().isNotEmpty) return tester.getRect(f);
  }
  throw StateError('no view mode button');
}

/// Problems with the bar in the current frame: bar parts covering each
/// other or anything else on the drive screen, or leaving the safe area
/// (the shared drive screen check), plus touch targets under 48 dp.
/// Problems the shared check finds between other parts (the HUD and its
/// notices) go to [elsewhere]: they are the HUD layout's, printed for
/// review.
List<String> _barProblems(WidgetTester tester, Set<String> elsewhere) {
  final report = LayoutReport();
  checkDriveScreen(tester, report);
  checkVisibleText(tester, report);
  final problems = <String>[];
  for (final p in report.problems) {
    final bar =
        p.startsWith('오류') ||
        _barParts.any(p.contains) ||
        chipStates.any((s) => p.contains(s.label));
    if (bar) {
      problems.add(p);
    } else {
      elsewhere.add(p);
    }
  }
  final targets = <String, Rect>{
    '화면 전환 버튼': _modeButton(tester),
    for (final tip in _buttonTips) tip: tester.getRect(find.byTooltip(tip)),
  };
  for (final MapEntry(:key, :value) in targets.entries) {
    if (value.width < 47.5 || value.height < 47.5) {
      problems.add('$key ${value.size} < 48');
    }
  }
  final chip = tester.getRect(_chip);
  if (chip.height < 47.5) problems.add('칩 높이 ${chip.height} < 48');
  // Explicit Rect checks for the bar, without the shared check's 1 px
  // allowance.
  final all = {...targets, '연결 상태 칩': chip};
  final names = all.keys.toList();
  for (var i = 0; i < names.length; i++) {
    for (var j = i + 1; j < names.length; j++) {
      if (all[names[i]]!.overlaps(all[names[j]]!)) {
        problems.add('겹침: ${names[i]} ↔ ${names[j]}');
      }
    }
  }
  final notice = find.byKey(const ValueKey('camera-notice'));
  if (notice.evaluate().isNotEmpty) {
    final card = tester.getRect(notice);
    for (final MapEntry(:key, :value) in all.entries) {
      if (card.overlaps(value)) problems.add('겹침: 카메라 안내 ↔ $key');
    }
  }
  return problems;
}

Future<void> _checkAllStates(
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
    () => Directory.systemTemp.createTemp('kl_bar_'),
  ))!;
  addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
  final auto = FixedAutoConnect();
  final problems = <String>[];
  final elsewhere = <String>{};
  final errors = await collectFlutterErrors(() async {
    await _pumpHome(tester, root, auto);
    for (final camera in [false, true]) {
      if (camera) {
        await tester.tap(find.byTooltip('카메라 화면으로 바꾸기'));
        await tester.pump();
        expect(find.byKey(const ValueKey('camera-notice')), findsOneWidget);
      }
      Rect? first;
      for (final state in chipStates) {
        auto.show(state);
        await tester.pump();
        final where = '${camera ? '카메라' : '3D'} "${state.label}"';
        expect(find.text(state.label), findsOneWidget, reason: where);
        for (final p in _barProblems(tester, elsewhere)) {
          problems.add('$where: $p');
        }
        // Right-aligned on the same row whatever it says.
        final chip = tester.getRect(_chip);
        first ??= chip;
        if ((chip.right - first.right).abs() > 0.5 ||
            (chip.bottom - first.bottom).abs() > 0.5) {
          problems.add('$where: 칩이 움직임 $first → $chip');
        }
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
  auto.dispose();
  if (elsewhere.isNotEmpty) {
    debugPrint(
      '${device.id} ${(textScale * 100).round()}%: '
      '하단 막대와 상관없는 문제 ${elsewhere.join(' / ')}',
    );
  }
  expect(errors, isEmpty);
  expect(problems.toSet().toList(), isEmpty);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('bar layout', () {
    test(
      'the chip shares the button row only when its longest wording fits',
      () {
        final wide = DriveBarLayout(
          width: 800,
          buttons: 3,
          chip: const Size(250, 48),
        );
        expect(wide.chipInline, isTrue);
        // 800 - mode button (18 + 48 + 10) - margin 18 - 3 buttons - gap 10.
        expect(wide.chipMaxWidth, 800 - 76 - 18 - 164 - 10);
        expect(wide.noticeRise, 0);

        final narrow = DriveBarLayout(
          width: 384,
          buttons: 3,
          chip: const Size(250, 48),
        );
        expect(narrow.chipInline, isFalse);
        expect(narrow.chipMaxWidth, 384 - 2 * DriveBar.margin);
        // Its own row: 8 dp over the button row, 48 dp tall.
        expect(narrow.chipRowBottom, DriveBar.bottom + 48 + 8);
        expect(narrow.height, DriveBar.bottom + 48 + 8 + 48);
        expect(narrow.noticeRise, narrow.height - DriveBar.oneRowClear);
        expect(narrow.noticeRise, greaterThan(0));

        final none = DriveBarLayout(width: 384, buttons: 3);
        expect(none.hasChip, isFalse);
        expect(none.noticeRise, 0);
        // One row fits the room the HUD always keeps for the buttons.
        expect(none.height, lessThanOrEqualTo(DriveBar.oneRowClear));
      },
    );

    test('a very tall chip lifts the notices by its own height', () {
      final bar = DriveBarLayout(
        width: 384,
        buttons: 3,
        chip: const Size(300, 70),
      );
      expect(bar.chipHeight, 70);
      expect(bar.height, DriveBar.bottom + 48 + 8 + 70);
    });
  });

  group('chip wordings', () {
    Future<AutoConnectController> run(
      WidgetTester tester,
      FakeProbe probe, {
      String? last = 'http://192.168.0.40:8082',
    }) async {
      final auto = AutoConnectController(
        target: FakeTarget(),
        probe: probe,
        listNetworks: () async => [LocalNetwork.named('wlan0', '192.168.0.23')],
        lastEndpoint: () => last,
      );
      auto.setEnabled(true);
      await _settle(tester);
      return auto;
    }

    testWidgets('the tests use the wordings the controller shows', (
      tester,
    ) async {
      final seen = <String>{};
      final idle = AutoConnectController(
        target: FakeTarget(),
        probe: FakeProbe(),
        listNetworks: () async => const [],
      );
      seen.add(idle.statusLabel); // off
      idle.dispose();

      final slow = FakeProbe()..delay = const Duration(seconds: 2);
      final searching = await run(tester, slow);
      expect(searching.phase, AutoConnectPhase.searching);
      seen.add(searching.statusLabel);
      searching.setForeground(false);
      expect(searching.phase, AutoConnectPhase.paused);
      seen.add(searching.statusLabel);
      searching.dispose();
      await tester.pump(const Duration(seconds: 3));

      final none = await run(tester, FakeProbe());
      expect(none.phase, AutoConnectPhase.waiting);
      seen.add(none.statusLabel);
      none.dispose();

      final refusing = FakeProbe();
      refusing.answers['192.168.0.40:8082'] = const ProbeResult.localOnly();
      final localOnly = await run(tester, refusing);
      expect(localOnly.localOnly, isNotEmpty);
      seen.add(localOnly.statusLabel);
      localOnly.dispose();

      // No saved comma: both answer the scan and the user picks one.
      final two = await run(
        tester,
        FakeProbe()
          ..device('192.168.0.40')
          ..device('192.168.0.41'),
        last: null,
      );
      expect(two.phase, AutoConnectPhase.choosing);
      seen.add(two.statusLabel);
      two.dispose();

      final one = await run(tester, FakeProbe()..device('192.168.0.40'));
      expect(one.phase, AutoConnectPhase.connected);
      seen.add(one.statusLabel);
      one.dispose();
      await tester.pump(const Duration(seconds: 1));

      expect(
        seen.map(_shape).toSet(),
        chipStates.map((s) => _shape(s.label)).toSet(),
      );
      expect(
        seen.map(_shape).toSet(),
        AutoConnectStatusChip.labelSamples.map(_shape).toSet(),
      );
    });
  });

  group('device bar', skip: !_realFonts, () {
    testWidgets('the chip keeps room for every wording', (tester) async {
      await tester.runAsync(loadReviewFonts);
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          theme: KovaLinkApp.theme(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      final room = AutoConnectStatusChip.longestSize(context);
      for (final state in chipStates) {
        final size = AutoConnectStatusChip.sizeFor(context, state.label);
        expect(size.width, lessThanOrEqualTo(room.width), reason: state.label);
      }
      // The longest is the comma that refuses phones.
      expect(
        AutoConnectStatusChip.sizeFor(context, longestChipState.label).width,
        room.width,
      );
    });

    testWidgets('16:39 phone: 콤마 없음 · 2초 뒤 다시 is clear of the mode button', (
      tester,
    ) async {
      await tester.runAsync(loadReviewFonts);
      reportedPhone.apply(tester);
      addTearDown(tester.view.reset);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('kl_bar_'),
      ))!;
      addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
      final auto = FixedAutoConnect(
        chipStates.firstWhere((s) => s.label == '콤마 없음 · 2초 뒤 다시'),
      );
      await _pumpHome(tester, root, auto);
      await tester.tap(find.byTooltip('카메라 화면으로 바꾸기'));
      await tester.pump();
      final chip = tester.getRect(_chip);
      final mode = _modeButton(tester);
      expect(chip.overlaps(mode), isFalse, reason: 'chip $chip, mode $mode');
      expect(
        chip.overlaps(
          tester.getRect(find.byKey(const ValueKey('camera-notice'))),
        ),
        isFalse,
      );
      // The whole wording is shown, not cut.
      final text = tester.renderObject<RenderParagraph>(
        find.text('콤마 없음 · 2초 뒤 다시'),
      );
      expect(text.didExceedMaxLines, isFalse);
      // Screen readers hear it once.
      expect(tester.getSemantics(_chip).label, '콤마 없음 · 2초 뒤 다시');
      await tester.pumpWidget(const SizedBox.shrink());
      auto.dispose();
    });

    testWidgets('mode button and round buttons share one row', (tester) async {
      await tester.runAsync(loadReviewFonts);
      final device = portraitDevices[2]; // iPhone 15: 34 dp indicator
      device.apply(tester);
      addTearDown(tester.view.reset);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('kl_bar_'),
      ))!;
      addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
      final auto = FixedAutoConnect(chipStates.last);
      await _pumpHome(tester, root, auto);
      final mode = _modeButton(tester);
      final bottom = device.height - device.padding.bottom - DriveBar.bottom;
      expect(mode.bottom, moreOrLessEquals(bottom));
      expect(mode.left, moreOrLessEquals(DriveBar.margin));
      for (final tip in _buttonTips) {
        expect(
          tester.getRect(find.byTooltip(tip)).bottom,
          moreOrLessEquals(bottom),
          reason: tip,
        );
      }
      expect(
        tester.getRect(find.byTooltip('설정')).right,
        moreOrLessEquals(device.width - DriveBar.margin),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      auto.dispose();
    });

    testWidgets('narrow phone: the chip row lifts the camera notice', (
      tester,
    ) async {
      await tester.runAsync(loadReviewFonts);
      reportedPhone.apply(tester);
      addTearDown(tester.view.reset);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('kl_bar_'),
      ))!;
      addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
      final auto = FixedAutoConnect(longestChipState);
      await _pumpHome(tester, root, auto);
      await tester.tap(find.byTooltip('카메라 화면으로 바꾸기'));
      await tester.pump();
      final chip = tester.getRect(_chip);
      final settingsButton = tester.getRect(find.byTooltip('설정'));
      // Own row, right-aligned over the round buttons.
      expect(chip.bottom, lessThan(settingsButton.top));
      expect(chip.right, moreOrLessEquals(settingsButton.right));
      final notice = tester.getRect(
        find.byKey(const ValueKey('camera-notice')),
      );
      expect(notice.bottom, lessThan(chip.top));
      final signal = tester.getRect(find.byType(SignalPill));
      expect(notice.top, greaterThan(signal.bottom));
      await tester.pumpWidget(const SizedBox.shrink());
      auto.dispose();
    });

    for (final device in [reportedPhone, ...allDevices]) {
      for (final scale in [1.0, 1.3]) {
        final name = scale == 1 ? device.id : '${device.id} with 130% text';
        testWidgets('$name (${device.label}): every chip wording', (
          tester,
        ) async {
          await _checkAllStates(tester, device, textScale: scale);
        });
      }
    }
  });
}
