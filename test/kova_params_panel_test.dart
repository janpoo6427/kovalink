import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/settings/kova_params_panel.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';

import 'support/fake_kova_gateway.dart';

KovaParamsController _controller(FakeKovaGateway gateway) =>
    KovaParamsController(
      clientFactory: (endpoint, onError) => KovaParamsClient.tryCreate(
        endpoint,
        transport: gateway,
        onError: onError,
      ),
      pollInterval: null,
    );

Future<void> _pumpPanel(WidgetTester tester, KovaParamsController kova) async {
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
}

void main() {
  late FakeKovaGateway gateway;
  late KovaParamsController kova;

  setUp(() {
    gateway = FakeKovaGateway();
    kova = _controller(gateway);
  });

  tearDown(() => kova.dispose());

  testWidgets('draws groups and settings only from the document', (
    tester,
  ) async {
    await _pumpPanel(tester, kova);
    expect(find.text('연결 안 됨'), findsOneWidget);
    expect(find.byKey(const ValueKey('kova-empty')), findsOneWidget);
    expect(find.text('항시 조향'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('kova-connect')));
    await tester.pump();
    expect(find.text('연결됨'), findsOneWidget);
    expect(find.text('조향'), findsOneWidget);
    expect(find.text('통신 시험용'), findsOneWidget);
    expect(find.text('항시 조향'), findsOneWidget);
    expect(find.text('숨긴 시험 항목'), findsNothing);
    expect(
      find.byKey(const ValueKey('kova-toggle-steering.always_on')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('kova-slider-e2e.level')), findsOneWidget);
    expect(find.byKey(const ValueKey('kova-choice-e2e.mode')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('kova-lock-e2e.build_label')),
      findsOneWidget,
    );
    expect(find.text('정차 중에만 변경'), findsOneWidget);
    expect(find.text('재시작 후 적용'), findsOneWidget);
    expect(find.text('준비 중'), findsOneWidget);
    expect(find.textContaining('개발용 연결'), findsOneWidget);

    // A renamed catalog title shows up without any app change.
    final steering = (gateway.catalog['settings'] as List)
        .cast<Map<String, dynamic>>()
        .first;
    (steering['title'] as Map)['ko'] = '새 이름';
    await tester.tap(find.byKey(const ValueKey('kova-refresh')));
    await tester.pump();
    expect(find.text('새 이름'), findsOneWidget);
  });

  testWidgets('description is short until 자세히 is tapped', (tester) async {
    await kova.connect('http://127.0.0.1:18082');
    await _pumpPanel(tester, kova);
    expect(
      find.byKey(const ValueKey('kova-details-steering.always_on')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('kova-more-steering.always_on')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('kova-details-steering.always_on')),
      findsOneWidget,
    );
    expect(find.textContaining('필요 기능: alwaysSteering'), findsOneWidget);
    expect(find.text('접기'), findsOneWidget);
  });

  testWidgets('control risk asks first; cancel sends nothing', (tester) async {
    await kova.connect('http://127.0.0.1:18082');
    await _pumpPanel(tester, kova);
    await tester.tap(
      find.byKey(const ValueKey('kova-toggle-steering.always_on')),
    );
    await tester.pumpAndSettle();
    expect(find.text('주행에 영향을 주는 설정'), findsOneWidget);
    expect(find.textContaining('실제 동작은 아직 바뀌지 않아요'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(gateway.posts, isEmpty);
  });

  testWidgets('confirmed change shows 보내는 중 until the gateway answers', (
    tester,
  ) async {
    await kova.connect('http://127.0.0.1:18082');
    await _pumpPanel(tester, kova);
    gateway.hold = Completer<void>();
    await tester.tap(
      find.byKey(const ValueKey('kova-toggle-steering.always_on')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kova-confirm-change')));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('kova-pending-steering.always_on')),
      findsOneWidget,
    );
    expect(kova.document!.setting('steering.always_on')!.value, isFalse);
    final toggle = tester.widget<Switch>(
      find.byKey(const ValueKey('kova-toggle-steering.always_on')),
    );
    expect(toggle.onChanged, isNull);

    gateway.hold!.complete();
    gateway.hold = null;
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('kova-pending-steering.always_on')),
      findsNothing,
    );
    expect(find.textContaining('저장했어요'), findsOneWidget);
    expect(kova.document!.setting('steering.always_on')!.value, isTrue);
  });

  testWidgets('enum sheet sends the picked option', (tester) async {
    await kova.connect('http://127.0.0.1:18082');
    await _pumpPanel(tester, kova);
    await tester.tap(find.byKey(const ValueKey('kova-choice-e2e.mode')));
    await tester.pumpAndSettle();
    expect(find.text('차분하게'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('kova-option-e2e.mode-lively')));
    await tester.pumpAndSettle();
    expect(gateway.posts.single['value'], 'lively');
    expect(find.text('활발하게'), findsWidgets);
  });

  testWidgets('number input rejects out-of-range text locally', (tester) async {
    await kova.connect('http://127.0.0.1:18082');
    await _pumpPanel(tester, kova);
    await tester.enterText(
      find.byKey(const ValueKey('kova-input-e2e.level')),
      '12',
    );
    await tester.tap(find.byKey(const ValueKey('kova-apply-e2e.level')));
    await tester.pump();
    expect(find.text('0–10 사이로 골라 주세요.'), findsOneWidget);
    expect(gateway.posts, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('kova-input-e2e.level')),
      '8',
    );
    await tester.tap(find.byKey(const ValueKey('kova-apply-e2e.level')));
    await tester.pump();
    await tester.pump();
    expect(gateway.posts.single['value'], 8);
    expect(kova.document!.setting('e2e.level')!.value, 8);
  });

  testWidgets('LAN connection is read-only with every control disabled', (
    tester,
  ) async {
    await kova.connect('http://192.168.0.10:8082');
    await _pumpPanel(tester, kova);
    expect(find.textContaining('보기만 할 수 있어요'), findsWidgets);
    final toggle = tester.widget<Switch>(
      find.byKey(const ValueKey('kova-toggle-steering.always_on')),
    );
    expect(toggle.onChanged, isNull);
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('kova-slider-e2e.level')),
    );
    expect(slider.onChanged, isNull);
    final choice = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('kova-choice-e2e.mode')),
    );
    expect(choice.onPressed, isNull);
    await tester.tap(
      find.byKey(const ValueKey('kova-toggle-steering.always_on')),
    );
    await tester.pump();
    expect(gateway.posts, isEmpty);
  });

  testWidgets('onroad banner and offroad item lock', (tester) async {
    gateway.offroad = false;
    await kova.connect('http://127.0.0.1:18082');
    await _pumpPanel(tester, kova);
    expect(find.byKey(const ValueKey('kova-onroad-banner')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('kova-lock-steering.always_on')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('kova-lock-e2e.level')), findsNothing);
  });

  testWidgets('conflict and rejection notices are drawn', (tester) async {
    await kova.connect('http://127.0.0.1:18082');
    await _pumpPanel(tester, kova);
    gateway.externalWrite('e2e.mode', 'calm');
    await kova.setValue('e2e.mode', 'lively');
    await tester.pump();
    expect(find.textContaining('다른 곳에서 먼저 바뀌었어요'), findsOneWidget);
    gateway.offroad = false;
    gateway.reportOffroad = false;
    await kova.refresh();
    await kova.setValue('steering.always_on', true);
    await tester.pump();
    expect(find.textContaining('주행 중에는 바꿀 수 없어요. 차를 세운 뒤'), findsOneWidget);
  });

  group('settings screen', () {
    Future<void> pumpScreen(
      WidgetTester tester,
      SettingsController settings,
    ) async {
      tester.view.physicalSize = const Size(900, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gatewayController = GatewayController();
      addTearDown(gatewayController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsScreen(
              controller: gatewayController,
              settings: settings,
              kovaParams: kova,
            ),
          ),
        ),
      );
    }

    testWidgets('app, session and kovapilot settings are separate tabs', (
      tester,
    ) async {
      final settings = SettingsController(store: MemorySettingsStore());
      await pumpScreen(tester, settings);
      expect(find.text('시점'), findsOneWidget);
      expect(find.byKey(const ValueKey('kova-connection-card')), findsNothing);

      await tester.tap(find.text('연결 상태'));
      await tester.pump();
      expect(find.byKey(const ValueKey('session-card')), findsOneWidget);
      expect(find.text('시점'), findsNothing);

      await tester.tap(find.text('kovapilot'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('kova-connection-card')),
        findsOneWidget,
      );
      expect(find.text(AppSettings.defaultSettingsEndpoint), findsOneWidget);
      expect(find.text('시점'), findsNothing);
    });
  });
}
