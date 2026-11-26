import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/settings/kova_params_panel.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/kova_params/kova_params_document.dart';

import 'support/fake_kova_gateway.dart';

// Settings that need openpilot longitudinal control are hidden, with a note
// naming them, until longitudinal control runs (janpoo 11/27).

Map<String, dynamic> _longitudinal(String state) => {
  'condition': 'openpilotLongitudinalApplied',
  'setting': 'cruise.openpilot_longitudinal',
  'title': {'ko': 'openpilot 종방향 제어'},
  'state': state,
};

Map<String, dynamic> _switch(
  String key,
  String group,
  int order,
  String title, {
  List<Map<String, dynamic>> dependencies = const [],
}) => {
  'key': key,
  'groupId': group,
  'order': order,
  'type': 'enum',
  'control': 'switch',
  'options': [0, 1],
  'optionTitles': {
    '0': {'ko': '끔'},
    '1': {'ko': '켬'},
  },
  'defaultValue': 0,
  'title': {'ko': title},
  'access': 'readWrite',
  'risk': 'control',
  'applyPolicy': 'parked',
  'savePolicy': 'anytime',
  'availability': 'available',
  'dependencies': dependencies,
};

Map<String, dynamic> _catalog(String? state) {
  final long = [if (state != null) _longitudinal(state)];
  return {
    'schemaVersion': 1,
    'defaultLocale': 'ko',
    'locales': ['ko'],
    'groups': [
      {
        'id': 'navigation',
        'order': 200,
        'title': {'ko': '내비게이션'},
      },
      {
        'id': 'display',
        'order': 250,
        'title': {'ko': '화면'},
      },
      {
        'id': 'cruise',
        'order': 300,
        'title': {'ko': '크루즈'},
      },
    ],
    'settings': [
      _switch(
        'navigation.speed_camera_profile',
        'navigation',
        100,
        '카메라 감속 프로필',
        dependencies: [
          ...long,
          {
            'condition': 'verifiedCameraInput',
            'title': {'ko': '검증된 내비 카메라 입력'},
            'state': 'met',
          },
        ],
      ),
      _switch('display.onroad_brightness_mode', 'display', 100, '화면 밝기 모드'),
      _switch(
        'cruise.accelerator_sync',
        'cruise',
        100,
        '악셀 동기화',
        dependencies: long,
      ),
      _switch(
        'cruise.curve_slowdown',
        'cruise',
        150,
        '커브 감속',
        dependencies: long,
      ),
      _switch(
        'cruise.accelerator_sync_stock_shadow',
        'cruise',
        200,
        '순정 ACC 악셀 동기화',
        dependencies: [
          {
            'condition': 'stockCruiseSpeedOwner',
            'title': {'ko': '순정 ACC 설정속도 제어'},
            'state': 'met',
          },
        ],
      ),
      _switch(
        'cruise.openpilot_longitudinal',
        'cruise',
        290,
        'openpilot 종방향 제어',
      ),
    ],
  };
}

Future<KovaParamsController> _pump(
  WidgetTester tester,
  String? state, {
  void Function(FakeKovaGateway gateway)? edit,
}) async {
  final gateway = FakeKovaGateway(catalog: _catalog(state));
  edit?.call(gateway);
  final kova = KovaParamsController(
    clientFactory: (endpoint, onError) => KovaParamsClient.tryCreate(
      endpoint,
      transport: gateway,
      onError: onError,
    ),
    pollInterval: null,
  );
  addTearDown(kova.dispose);
  await kova.connect('http://127.0.0.1:18082');
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            KovaParamsPanel(
              controller: kova,
              address: 'http://127.0.0.1:18082',
            ),
          ],
        ),
      ),
    ),
  );
  for (final id in ['navigation', 'display', 'cruise']) {
    await tester.tap(find.byKey(PageStorageKey('kova-group-panel-$id')));
    await tester.pumpAndSettle();
  }
  return kova;
}

Finder _tile(String key) => find.byKey(ValueKey('kova-setting-$key'));

const _longOnly = [
  'navigation.speed_camera_profile',
  'cruise.accelerator_sync',
  'cruise.curve_slowdown',
];
const _always = [
  'display.onroad_brightness_mode',
  'cruise.accelerator_sync_stock_shadow',
  'cruise.openpilot_longitudinal',
];

void main() {
  test(
    'only the longitudinal condition blocks, and only when it is not met',
    () {
      KovaParamSetting setting(List<Map<String, dynamic>> deps) =>
          KovaParamSetting.parse(
            _switch('a.b', 'g', 1, 'x', dependencies: deps),
          );
      for (final state in ['unmet', 'pendingRestart', 'unsupported']) {
        expect(setting([_longitudinal(state)]).longitudinalBlock, state);
      }
      for (final state in ['met', 'unknown', 'pendingConsumer']) {
        expect(setting([_longitudinal(state)]).longitudinalBlock, isNull);
      }
      expect(setting([]).longitudinalBlock, isNull);
      // Same title without the gateway condition id (e.g. older gateways).
      expect(
        setting([
          {
            'title': {'ko': 'openpilot 종방향 제어'},
            'state': 'unmet',
          },
        ]).longitudinalBlock,
        isNull,
      );
      expect(
        setting([
          {
            'condition': 'openpilotCruiseSpeedOwner',
            'title': {'ko': 'KOVA 크루즈 설정속도 제어'},
            'state': 'unmet',
          },
        ]).longitudinalBlock,
        isNull,
      );
    },
  );

  testWidgets('longitudinal off: hides what needs it and names it in place', (
    tester,
  ) async {
    await _pump(tester, 'unmet');
    for (final key in _longOnly) {
      expect(_tile(key), findsNothing, reason: key);
    }
    for (final key in _always) {
      expect(_tile(key), findsOneWidget, reason: key);
    }
    expect(find.text('종방향 제어를 켜면 사용할 수 있는 기능: 악셀 동기화, 커브 감속'), findsOneWidget);
    expect(find.text('종방향 제어를 켜면 사용할 수 있는 기능: 카메라 감속 프로필'), findsOneWidget);
    expect(find.byKey(const ValueKey('kova-long-only-display')), findsNothing);
    expect(find.text('2개 항목 · 종방향 제어 필요 2개'), findsOneWidget);
    expect(find.text('0개 항목 · 종방향 제어 필요 1개'), findsOneWidget);
    // The note stands where the first hidden setting was: before the others.
    final note = tester.getTopLeft(
      find.byKey(const ValueKey('kova-long-only-cruise')),
    );
    expect(
      note.dy,
      lessThan(
        tester.getTopLeft(_tile('cruise.accelerator_sync_stock_shadow')).dy,
      ),
    );
  });

  testWidgets('longitudinal running: every setting shows as before', (
    tester,
  ) async {
    await _pump(tester, 'met');
    for (final key in [..._longOnly, ..._always]) {
      expect(_tile(key), findsOneWidget, reason: key);
    }
    expect(find.textContaining('종방향 제어를 켜면'), findsNothing);
    expect(find.textContaining('종방향 제어 필요'), findsNothing);
    expect(find.text('4개 항목'), findsOneWidget);
  });

  testWidgets('vehicle not known yet: settings stay visible', (tester) async {
    await _pump(tester, 'unknown');
    for (final key in [..._longOnly, ..._always]) {
      expect(_tile(key), findsOneWidget, reason: key);
    }
    expect(find.textContaining('사용할 수 있는 기능'), findsNothing);
  });

  testWidgets('saved for the next start: says so and keeps them hidden', (
    tester,
  ) async {
    await _pump(tester, 'pendingRestart');
    for (final key in _longOnly) {
      expect(_tile(key), findsNothing, reason: key);
    }
    expect(
      find.text('종방향 제어가 저장됐어요 · 다음 시동부터 사용할 수 있는 기능: 악셀 동기화, 커브 감속'),
      findsOneWidget,
    );
  });

  testWidgets('unsupported vehicle: says the car cannot', (tester) async {
    await _pump(tester, 'unsupported');
    for (final key in _longOnly) {
      expect(_tile(key), findsNothing, reason: key);
    }
    expect(
      find.text('이 차량은 종방향 제어를 지원하지 않아요 · 사용할 수 없는 기능: 악셀 동기화, 커브 감속'),
      findsOneWidget,
    );
    expect(find.textContaining('켜면 사용할 수 있는'), findsNothing);
  });

  testWidgets('hidden settings do not raise the onroad banner', (tester) async {
    await _pump(
      tester,
      'unmet',
      edit: (gateway) {
        gateway.offroad = false;
        for (final s
            in (gateway.catalog['settings'] as List)
                .cast<Map<String, dynamic>>()) {
          s['savePolicy'] = 'parked';
          if (!_longOnly.contains(s['key'])) s['applyPolicy'] = 'immediate';
        }
      },
    );
    expect(find.byKey(const ValueKey('kova-onroad-banner')), findsNothing);
  });

  testWidgets('a visible parked setting still raises the onroad banner', (
    tester,
  ) async {
    await _pump(
      tester,
      'unmet',
      edit: (gateway) {
        gateway.offroad = false;
        for (final s
            in (gateway.catalog['settings'] as List)
                .cast<Map<String, dynamic>>()) {
          s['savePolicy'] = 'parked';
        }
      },
    );
    expect(find.byKey(const ValueKey('kova-onroad-banner')), findsOneWidget);
  });
}
