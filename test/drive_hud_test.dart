import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/hud/drive_hud.dart';
import 'package:kovalink/src/models/display_units.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';

Duration _s(double seconds) => Duration(milliseconds: (seconds * 1000).round());

Future<void> _pumpHud(
  WidgetTester tester,
  RoadScene scene, {
  Size size = const Size(1200, 900),
  SpeedUnit unit = SpeedUnit.kph,
  bool showNumbers = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DriveHud(
          scene: scene,
          compact: size.width < 680,
          unit: unit,
          showNumbers: showNumbers,
        ),
      ),
    ),
  );
}

void main() {
  group('display units', () {
    test('converts speeds and formats distances and durations', () {
      expect(SpeedUnit.kph.roundedFromMps(27.7778), 100);
      expect(SpeedUnit.mph.roundedFromMps(27.7778), 62);
      expect(SpeedUnit.mph.fromKph(100).round(), 62);
      expect(SpeedUnit.kph.roundedFromMps(-3), 0);
      expect(SpeedUnit.mph.label, 'mph');
      expect(formatDistance(545.4), '545 m');
      expect(formatDistance(1100), '1.1 km');
      expect(formatDistance(17500), '17.5 km');
      expect(formatDistance(123456), '123 km');
      expect(formatDistance(-1), '–');
      expect(formatDistanceCompact(42), '42m');
      expect(formatDuration(720), '12분');
      expect(formatDuration(3600), '1시간 0분');
    });
  });

  group('drive HUD', () {
    testWidgets('city stop: standby pill, red light countdown, turn row', (
      tester,
    ) async {
      await _pumpHud(tester, DemoDriveScenario().sceneAt(_s(0.5)));
      expect(find.text('0'), findsOneWidget);
      expect(find.text('km/h'), findsOneWidget);
      expect(find.text('조향 보조 대기'), findsOneWidget);
      expect(find.text('6초'), findsOneWidget);
      expect(find.text('신호등 12 m'), findsOneWidget);
      expect(find.text('제한속도'), findsOneWidget);
      expect(find.text('50'), findsWidgets);
      expect(find.text('좌회전'), findsOneWidget);
      expect(find.text('서울대학로278번길'), findsOneWidget);
      expect(find.text('목적지까지'), findsOneWidget);
      expect(find.byType(TrafficLightGlyph), findsOneWidget);
    });

    testWidgets('city turn approach shows the green sign and lane guidance', (
      tester,
    ) async {
      final scene = DemoDriveScenario().sceneAt(_s(85));
      await _pumpHud(tester, scene);
      expect(find.byType(TurnSign), findsOneWidget);
      expect(find.byType(LaneGuidancePill), findsOneWidget);
      expect(
        find.text(formatDistanceCompact(scene.tbt!.nextDistanceMeters!)),
        findsOneWidget,
      );
      expect(
        find.text('좌회전'),
        findsOneWidget,
        reason: 'label only in the info card',
      );
    });

    testWidgets('highway: engaged, set speed, camera, tollgate, destination', (
      tester,
    ) async {
      final scene = DemoDriveScenario(route: DemoRoute.highway).sceneAt(_s(10));
      await _pumpHud(tester, scene);
      expect(find.text('조향 보조 작동 중'), findsOneWidget);
      expect(find.text('설정'), findsOneWidget);
      expect(find.text('과속 카메라'), findsOneWidget);
      expect(find.text(' · 100 km/h'), findsOneWidget);
      expect(find.text('톨게이트'), findsOneWidget);
      expect(find.text('경부고속도로'), findsOneWidget);
      expect(find.byType(TurnSign), findsNothing);
      expect(find.byType(TrafficLightGlyph), findsNothing);
      expect(find.text('100'), findsWidgets);
    });

    testWidgets('mph converts speed, set speed, limit and camera limit', (
      tester,
    ) async {
      final scene = DemoDriveScenario(route: DemoRoute.highway).sceneAt(_s(10));
      await _pumpHud(tester, scene, unit: SpeedUnit.mph);
      expect(find.text('mph'), findsOneWidget);
      expect(find.text('km/h'), findsNothing);
      expect(find.text('62'), findsWidgets);
      expect(find.text(' · 62 mph'), findsOneWidget);
    });

    testWidgets('HUD numbers can be hidden', (tester) async {
      await _pumpHud(
        tester,
        DemoDriveScenario().sceneAt(_s(30)),
        showNumbers: false,
      );
      expect(find.text('제한속도'), findsNothing);
      expect(find.text('km/h'), findsNothing);
      expect(
        find.byType(SignalPill),
        findsOneWidget,
        reason: 'blinkers stay visible',
      );
    });

    testWidgets('blinker arrow lights during the lane change', (tester) async {
      final scene = DemoDriveScenario().sceneAt(_s(55));
      await _pumpHud(tester, scene);
      final left = tester.widget<Icon>(
        find.byKey(const ValueKey('blinker-left')),
      );
      final right = tester.widget<Icon>(
        find.byKey(const ValueKey('blinker-right')),
      );
      final blinkOn = (scene.monotonicTimeNanos ~/ 500000000).isEven;
      expect(
        left.color,
        blinkOn ? HudColors.signalGreen : isNot(HudColors.signalGreen),
      );
      expect(right.color, isNot(HudColors.signalGreen));
    });

    testWidgets('fits phone portrait and tablet layouts without overflow', (
      tester,
    ) async {
      for (final route in DemoRoute.values) {
        final scenario = DemoDriveScenario(route: route);
        for (final t in [0.5, 30.0, 55.0, 85.0]) {
          for (final size in const [
            Size(392, 850),
            Size(1200, 900),
            Size(1081, 1200),
          ]) {
            await _pumpHud(tester, scenario.sceneAt(_s(t)), size: size);
            expect(tester.takeException(), isNull, reason: '$route $t s $size');
          }
        }
      }
    });
  });
}
