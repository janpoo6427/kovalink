import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/settings/vehicle_features_card.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/gateway_controller.dart';

void main() {
  testWidgets(
    'zero objects never means radar off; BSM and lane setting separate',
    (tester) async {
      final gateway = GatewayController()
        ..mode = GatewayMode.live
        ..lastTelemetryAt = DateTime.now()
        ..scene = RoadScene.fromJson({
          'schemaVersion': 2,
          'monotonicTimeNanos': 0,
          'speedMps': 0,
          'setSpeedMps': 0,
          'steeringAngleDegrees': 0,
          'engaged': false,
          'objects': [],
          'plannedPath': [],
          'leftLane': [],
          'rightLane': [],
          'autoLaneChange': {
            'setting': 'on',
            'laneChange': 'off',
            'auto': 'none',
            'blindSpotLeft': false,
            'blindSpotRight': true,
            'blindSpotFresh': true,
          },
        });
      final settings = KovaParamsController(pollInterval: null);
      addTearDown(gateway.dispose);
      addTearDown(settings.dispose);
      tester.view.physicalSize = const Size(412, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: VehicleFeaturesCard(gateway: gateway, settings: settings),
            ),
          ),
        ),
      );
      // a build before the three modes sends setting on only: automatic
      expect(find.text('자동'), findsOneWidget);
      expect(find.textContaining('현재 동작 · 대기'), findsOneWidget);
      expect(find.text('신호 수신'), findsOneWidget);
      expect(find.textContaining('왼쪽 경고 없음 · 오른쪽 감지'), findsOneWidget);
      expect(find.text('레이더 트랙'), findsOneWidget);
      expect(find.text('확인할 수 없음'), findsOneWidget);
      expect(find.text('꺼짐'), findsNothing);
      expect(tester.takeException(), isNull);
      gateway.lastTelemetryAt = DateTime.now().subtract(
        const Duration(seconds: 10),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('자동'), findsNothing);
      expect(find.text('신호 수신'), findsNothing);
      expect(find.text('확인할 수 없음'), findsNWidgets(3));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('demo is not reported as real vehicle capability', (
    tester,
  ) async {
    final gateway = GatewayController()..mode = GatewayMode.demo;
    final settings = KovaParamsController(pollInterval: null);
    addTearDown(gateway.dispose);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: VehicleFeaturesCard(gateway: gateway, settings: settings),
          ),
        ),
      ),
    );
    expect(find.textContaining('데모 화면'), findsOneWidget);
    expect(find.text('확인할 수 없음'), findsNWidgets(3));
    expect(find.text('사용 중'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('lane change mode from the gateway, older builds from setting', () {
    AutoLaneChangeMode mode(Map<String, dynamic> json) =>
        AutoLaneChangeStatus.fromJson(json).mode;
    expect(mode({'mode': 'off', 'setting': 'off'}), AutoLaneChangeMode.off);
    expect(mode({'mode': 'nudge', 'setting': 'off'}), AutoLaneChangeMode.nudge);
    expect(mode({'mode': 'auto', 'setting': 'on'}), AutoLaneChangeMode.auto);
    expect(mode({'mode': 'new'}), AutoLaneChangeMode.unknown);
    expect(mode({'setting': 'on'}), AutoLaneChangeMode.auto);
    expect(mode({'setting': 'off'}), AutoLaneChangeMode.nudge);
    expect(mode({}), AutoLaneChangeMode.unknown);
  });

  for (final (name, label) in [
    ('off', '끔'),
    ('nudge', '조향 개입 시'),
    ('auto', '자동'),
  ]) {
    testWidgets('lane change mode $name shows $label', (tester) async {
      final gateway = GatewayController()
        ..mode = GatewayMode.live
        ..lastTelemetryAt = DateTime.now()
        ..scene = RoadScene.fromJson({
          'schemaVersion': 2,
          'monotonicTimeNanos': 0,
          'speedMps': 0,
          'setSpeedMps': 0,
          'steeringAngleDegrees': 0,
          'engaged': false,
          'objects': [],
          'plannedPath': [],
          'leftLane': [],
          'rightLane': [],
          'autoLaneChange': {
            'setting': name == 'auto' ? 'on' : 'off',
            'mode': name,
            'laneChange': 'off',
            'auto': 'none',
          },
        });
      final settings = KovaParamsController(pollInterval: null);
      addTearDown(gateway.dispose);
      addTearDown(settings.dispose);
      tester.view.physicalSize = const Size(412, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: VehicleFeaturesCard(gateway: gateway, settings: settings),
            ),
          ),
        ),
      );
      expect(find.text('차선 변경'), findsOneWidget);
      expect(find.text(label), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('runtime states preserve off, waiting, unsupported and unknown', () {
    expect(runtimeFeatureLabel('active'), '사용 중');
    expect(runtimeFeatureLabel('waiting'), '대기');
    expect(runtimeFeatureLabel('unsupported'), '이 차량에서 미지원');
    expect(runtimeFeatureLabel('off'), '꺼짐');
    expect(runtimeFeatureLabel('new-state'), '확인할 수 없음');
  });
}
