import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';

Duration _s(double seconds) => Duration(milliseconds: (seconds * 1000).round());

/// Compact fingerprint of a frame for equality checks.
String _fingerprint(RoadScene scene) => [
  scene.monotonicTimeNanos,
  scene.speedMps.toStringAsFixed(6),
  scene.odometerMeters.toStringAsFixed(6),
  scene.leftBlinker,
  scene.brakeActive,
  scene.plannedPath.map((p) => p.leftMeters.toStringAsFixed(5)).join(','),
  scene.objects
      .map(
        (o) =>
            '${o.id}:${o.distanceMeters.toStringAsFixed(5)}:${o.leftMeters.toStringAsFixed(5)}',
      )
      .join(';'),
].join('|');

void main() {
  group('demo drive scenario', () {
    for (final route in DemoRoute.values) {
      test('$route is deterministic for a fixed seed', () {
        final a = DemoDriveScenario(route: route);
        final b = DemoDriveScenario(route: route);
        for (final t in [0.0, 7.3, 25.0, 44.4, 57.0, 71.2, 89.9]) {
          expect(
            _fingerprint(a.sceneAt(_s(t))),
            _fingerprint(b.sceneAt(_s(t))),
            reason: '$t s',
          );
        }
      });

      test('$route seed changes only background traffic', () {
        final a = DemoDriveScenario(route: route, seed: 1);
        final b = DemoDriveScenario(route: route, seed: 2);
        final sceneA = a.sceneAt(_s(30));
        final sceneB = b.sceneAt(_s(30));
        expect(sceneA.speedMps, sceneB.speedMps);
        expect(sceneA.odometerMeters, sceneB.odometerMeters);
        String traffic(RoadScene s) => s.objects
            .where((o) => (o.id ?? 0) >= 100 && (o.id ?? 0) < 500)
            .map((o) => o.distanceMeters.toStringAsFixed(3))
            .join(',');
        expect(traffic(sceneA), isNot(traffic(sceneB)));
      });

      test('$route loops every ${DemoDriveScenario.period.inSeconds} s', () {
        final scenario = DemoDriveScenario(route: route);
        final first = scenario.sceneAt(_s(12.5));
        final second = scenario.sceneAt(_s(12.5) + DemoDriveScenario.period);
        expect(second.speedMps, first.speedMps);
        expect(second.odometerMeters, first.odometerMeters);
        expect(
          second.monotonicTimeNanos,
          greaterThan(first.monotonicTimeNanos),
        );
      });

      test('$route frames are complete, typed and display-only', () {
        final scenario = DemoDriveScenario(route: route);
        for (var t = 0.0; t < 90; t += 2.5) {
          final scene = scenario.sceneAt(_s(t));
          expect(scene.laneLines.length, greaterThanOrEqualTo(3));
          expect(scene.roadEdges, hasLength(2));
          expect(scene.plannedPath.length, greaterThan(10));
          expect(scene.gear, VehicleGear.drive);
          expect(scene.speedMps, inInclusiveRange(0, 30));
          expect(scene.tbt, isNotNull);
          expect(scene.speedLimitKph, isNotNull);
          expect(
            scene.roadType,
            route == DemoRoute.city ? RoadType.city : RoadType.highway,
          );
          expect(scene.objects.where((o) => o.isLead), hasLength(1));
          for (final object in scene.objects) {
            final insideEgo =
                object.distanceMeters < 0 &&
                object.distanceMeters + object.length > -4.5 &&
                object.leftMeters.abs() < 1.8;
            expect(
              insideEgo,
              isFalse,
              reason: 'object ${object.id} overlaps the ego at $t s',
            );
          }
        }
      });
    }

    test(
      'city script: stop, straight, curve, lead approach, lane change, turn',
      () {
        final city = DemoDriveScenario();
        expect(city.phaseAt(_s(2)), DemoPhase.stopped);
        expect(city.phaseAt(_s(10)), DemoPhase.straight);
        expect(city.phaseAt(_s(29)), DemoPhase.curve);
        expect(city.phaseAt(_s(45)), DemoPhase.leadApproach);
        expect(city.phaseAt(_s(56)), DemoPhase.laneChange);
        expect(city.phaseAt(_s(80)), DemoPhase.approachTurn);

        final stopped = city.sceneAt(_s(2));
        expect(stopped.speedMps, 0);
        expect(stopped.brakeActive, isTrue);
        expect(stopped.engaged, isFalse);
        expect(stopped.trafficSignal?.state, TrafficSignalState.red);
        expect(stopped.tbt?.maneuver, TbtManeuver.turnLeft);

        final curve = city.sceneAt(_s(29));
        expect(
          curve.plannedPath.last.leftMeters,
          lessThan(-5),
          reason: 'right-hand curve',
        );
        expect(
          curve.objects.where((o) => o.kind == TrackedObjectKind.trafficCone),
          isNotEmpty,
        );

        double leadGap(double t) =>
            city.sceneAt(_s(t)).leadObject!.distanceMeters;
        expect(
          leadGap(48),
          lessThan(leadGap(39) - 8),
          reason: 'lead approaches',
        );
        expect(city.sceneAt(_s(46)).brakeActive, isTrue);

        final change = city.sceneAt(_s(55));
        expect(change.leftBlinker, isTrue);
        final pathAt30 = RoadScene.interpolateLeft(change.plannedPath, 30);
        expect(
          pathAt30,
          greaterThan(1),
          reason: 'path bends into the left lane',
        );

        final turn = city.sceneAt(_s(85));
        expect(turn.laneGuidance.first.recommended, isTrue);
        expect(
          turn.tbt!.distanceMeters,
          lessThan(city.sceneAt(_s(70)).tbt!.distanceMeters),
        );
        expect(turn.trafficSignal?.state, TrafficSignalState.red);
      },
    );

    test('highway script: alerts, curve, lead approach and lane change', () {
      final highway = DemoDriveScenario(route: DemoRoute.highway);
      final cruise = highway.sceneAt(_s(10));
      expect(cruise.speedKph, greaterThan(85));
      expect(
        cruise.roadAlerts.map((a) => a.kind),
        contains(RoadAlertKind.speedCamera),
      );
      expect(
        cruise.roadAlerts.map((a) => a.kind),
        contains(RoadAlertKind.tollgate),
      );
      expect(cruise.trafficSignal, isNull);
      expect(
        highway.sceneAt(_s(25)).plannedPath.last.leftMeters,
        greaterThan(3),
      );
      expect(
        highway.sceneAt(_s(46)).leadObject!.distanceMeters,
        lessThan(highway.sceneAt(_s(36)).leadObject!.distanceMeters - 10),
      );
      expect(highway.sceneAt(_s(53)).leftBlinker, isTrue);
      final after = highway.sceneAt(_s(75));
      expect(after.leadObject!.distanceMeters, closeTo(34.8, 0.3));
      expect(after.leadObject!.id, 2);
    });

    test('odometer grows monotonically within a loop', () {
      final scenario = DemoDriveScenario();
      var previous = -1.0;
      for (var t = 0.0; t < 90; t += 0.5) {
        final odometer = scenario.sceneAt(_s(t)).odometerMeters;
        expect(odometer, greaterThanOrEqualTo(previous));
        previous = odometer;
      }
      expect(scenario.loopDistance, greaterThan(500));
    });
  });

  group('gateway controller demo', () {
    testWidgets('advances exactly one frame per tick and can be stopped', (
      tester,
    ) async {
      final controller = GatewayController();
      controller.startDemo();
      expect(controller.mode, GatewayMode.demo);
      for (var i = 0; i < 60; i++) {
        await tester.pump(GatewayController.demoFrameInterval);
      }
      expect(controller.demoElapsed, const Duration(seconds: 3));
      final expected = DemoDriveScenario().sceneAt(const Duration(seconds: 3));
      expect(_fingerprint(controller.scene), _fingerprint(expected));

      controller.startDemo(route: DemoRoute.highway);
      expect(controller.demoRoute, DemoRoute.highway);
      expect(controller.demoElapsed, Duration.zero);
      expect(controller.scene.roadType, RoadType.highway);

      controller.stopDemo();
      expect(controller.mode, GatewayMode.disconnected);
      expect(controller.scene.objects, isEmpty);
      expect(controller.scenario, isNull);
      final frozen = controller.scene;
      await tester.pump(const Duration(seconds: 1));
      expect(
        identical(controller.scene, frozen),
        isTrue,
        reason: 'timer cancelled',
      );
      controller.dispose();
    });
  });
}
