import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/road_view/hud/drive_hud.dart';
import 'package:kovalink/src/features/road_view/hud/nav_cards.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';

/// A telemetry frame as the kovapilot gateway sends it with the carrot
/// modified TMAP connected (gateway/navigation_status.py).
Map<String, dynamic> frame({
  Map<String, dynamic>? navigation,
  Map<String, dynamic>? tbt,
  Map<String, dynamic>? autoLaneChange,
}) => {
  'schemaVersion': 1,
  'monotonicTimeNanos': 1000000000,
  'speedMps': 16.0,
  'gear': 'drive',
  'leftBlinker': false,
  'rightBlinker': false,
  'brakeActive': false,
  'speedLimitKph': 50.0,
  'navigation': ?navigation,
  'tbt': ?tbt,
  'autoLaneChange': ?autoLaneChange,
};

const v2 = {
  'source': 'carrotV2',
  'appVersion': '11.2.3.3740',
  'lastReceivedAgeMs': 250,
  'guidanceActive': true,
  'offRoute': false,
};

const turn = {
  'maneuver': 'turnLeft',
  'turnType': 12,
  'distanceMeters': 300.0,
  'roadName': '테헤란로',
  'mainText': '역삼역 좌회전',
  'nearDirection': null,
  'nextManeuver': 'slightRight',
  'nextTurnType': 101,
  'nextDistanceMeters': 1200.0,
  'nextRoadName': '강변북로',
  'remainingDistanceMeters': 12300.0,
  'remainingSeconds': 840,
};

Map<String, dynamic> laneChange({
  String setting = 'on',
  String phase = 'off',
  String direction = 'none',
  String auto = 'unknown',
  bool? fresh,
}) => {
  'setting': setting,
  'laneChange': phase,
  'direction': direction,
  'auto': auto,
  'blindSpotFresh': fresh,
  'blindSpotLeft': false,
  'blindSpotRight': true,
};

Future<HudLayout> pumpHud(
  WidgetTester tester,
  RoadScene scene, {
  Size size = const Size(1200, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DriveHud(scene: scene, compact: size.width < 680),
      ),
    ),
  );
  return HudLayout(size, compact: size.width < 680, showNumbers: true);
}

void main() {
  test('gateway frame parses navigation, guidance text and lane change', () {
    final scene = RoadScene.fromJson(
      frame(navigation: v2, tbt: turn, autoLaneChange: laneChange()),
    );
    expect(scene.navigation!.source, NavigationSource.carrotV2);
    expect(scene.navigation!.lastReceivedAgeMs, 250);
    expect(scene.tbt!.maneuver, TbtManeuver.turnLeft);
    expect(scene.tbt!.mainText, '역삼역 좌회전');
    expect(scene.autoLaneChange!.setting, AutoLaneChangeSetting.on);
    expect(scene.autoLaneChange!.direction, isNull);
    expect(scene.autoLaneChange!.blindSpotFresh, isNull);
    final old = RoadScene.fromJson(frame());
    expect(old.navigation, isNull);
    expect(old.autoLaneChange, isNull);
  });

  testWidgets('turn-by-turn card from the connected TMAP app', (tester) async {
    await pumpHud(tester, RoadScene.fromJson(frame(navigation: v2, tbt: turn)));
    expect(find.byKey(const ValueKey('tbt-card')), findsOneWidget);
    expect(find.text('300 m'), findsOneWidget);
    expect(find.text('역삼역 좌회전'), findsOneWidget);
    expect(find.text('다음'), findsOneWidget);
    expect(find.text('1.2 km'), findsOneWidget);
    expect(find.text('목적지까지 12.3 km · 14분'), findsOneWidget);
    expect(find.text('TMAP 연결 · 0.3초 전 받음'), findsOneWidget);
    expect(find.byIcon(Icons.turn_left_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('lane-change-card')), findsNothing);
  });

  testWidgets(
    'no turn-by-turn card from the demo, the old app or without guidance',
    (tester) async {
      await pumpHud(
        tester,
        DemoDriveScenario().sceneAt(const Duration(seconds: 85)),
      );
      expect(find.byKey(const ValueKey('tbt-card')), findsNothing);
      await pumpHud(
        tester,
        RoadScene.fromJson(
          frame(navigation: {'source': 'carrotLegacy'}, tbt: turn),
        ),
      );
      expect(find.byKey(const ValueKey('tbt-card')), findsNothing);
      await pumpHud(tester, RoadScene.fromJson(frame(navigation: v2)));
      expect(find.byKey(const ValueKey('tbt-card')), findsNothing);
      expect(
        navigationLinkText(
          const NavigationLink(
            source: NavigationSource.carrotV2,
            offRoute: true,
          ),
        ),
        'TMAP 연결 · 받은 시각 모름 · 경로 이탈',
      );
    },
  );

  testWidgets('lane change card: setting, state, blind spots, unknowns', (
    tester,
  ) async {
    await pumpHud(
      tester,
      RoadScene.fromJson(frame(autoLaneChange: laneChange())),
    );
    expect(find.byKey(const ValueKey('lane-change-card')), findsOneWidget);
    expect(find.text('자동 차선 변경 켬'), findsOneWidget);
    expect(find.text('대기'), findsOneWidget);
    expect(find.text('BSM 왼쪽 없음 · 오른쪽 감지'), findsOneWidget);
    expect(find.text('BSM 신호 모름'), findsOneWidget);
    expect(find.text('막힌 이유 모름'), findsOneWidget);
    // setting off and no lane change: no card
    await pumpHud(
      tester,
      RoadScene.fromJson(frame(autoLaneChange: laneChange(setting: 'off'))),
    );
    expect(find.byKey(const ValueKey('lane-change-card')), findsNothing);
    // a lane change with the setting off still shows what happens
    await pumpHud(
      tester,
      RoadScene.fromJson(
        frame(
          autoLaneChange: laneChange(
            setting: 'off',
            phase: 'preLaneChange',
            direction: 'left',
            auto: 'none',
            fresh: false,
          ),
        ),
      ),
    );
    expect(find.text('왼쪽 깜빡이 · 핸들을 밀어 주세요'), findsOneWidget);
    expect(find.text('BSM 신호 끊김'), findsOneWidget);
  });

  test('lane change state labels', () {
    String label(String phase, String auto, [String direction = 'right']) =>
        laneChangeStateText(
          AutoLaneChangeStatus.fromJson(
            laneChange(phase: phase, auto: auto, direction: direction),
          ),
        );
    expect(label('off', 'none', 'none'), '대기');
    expect(label('preLaneChange', 'pending'), '오른쪽 깜빡이 대기 · 곧 자동 변경');
    expect(label('preLaneChange', 'waiting'), '오른쪽 옆 차선 확인 기다림');
    expect(label('preLaneChange', 'unknown'), '오른쪽 깜빡이 켜짐');
    expect(label('laneChangeStarting', 'none'), '오른쪽 차선 변경 중');
    expect(label('laneChangeFinishing', 'returning'), '원래 차선으로 되돌아감');
    expect(label('unknown', 'unknown'), '모름');
  });

  testWidgets(
    'cards fit phones and tablets, clear of the navigation app overlay',
    (tester) async {
      final scene = RoadScene.fromJson(
        frame(
          navigation: v2,
          tbt: turn,
          autoLaneChange: laneChange(
            phase: 'preLaneChange',
            auto: 'pending',
            direction: 'left',
          ),
        ),
      );
      for (final size in const [
        Size(392, 850),
        Size(850, 392),
        Size(1200, 900),
        Size(1081, 1200),
      ]) {
        final layout = await pumpHud(tester, scene, size: size);
        expect(tester.takeException(), isNull, reason: '$size');
        final cards = [
          for (final key in const ['tbt-card', 'lane-change-card'])
            if (find.byKey(ValueKey(key)).evaluate().isNotEmpty)
              tester.getRect(find.byKey(ValueKey(key))),
        ];
        expect(cards, isNotEmpty, reason: '$size');
        for (final rect in cards) {
          expect(
            rect.overlaps(layout.navOverlayZone),
            isFalse,
            reason: '$size $rect',
          );
          expect(
            rect.overlaps(layout.signalRow),
            isFalse,
            reason: '$size $rect',
          );
          expect(rect.bottom <= size.height, isTrue, reason: '$size $rect');
        }
        if (layout.short) {
          // one card at a time on a landscape phone: the lane change going on
          expect(find.byKey(const ValueKey('tbt-card')), findsNothing);
          expect(
            find.byKey(const ValueKey('lane-change-card')),
            findsOneWidget,
          );
        }
      }
    },
  );
}
