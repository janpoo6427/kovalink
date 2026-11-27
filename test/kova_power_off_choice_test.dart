// 자동 전원 끄기(power.auto_power_off_minutes): 49개 목록(항상 켜둠, 30분~24시간)을
// 설정 화면에서 스크롤해 고르고, 고른 값이 정수 분으로 가고 현재 값이 보인다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/settings/kova_params_panel.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';

import 'support/fake_kova_gateway.dart';

const _key = 'power.auto_power_off_minutes';
final _options = [0, for (var m = 30; m <= 24 * 60; m += 30) m];

String _title(int minutes) {
  if (minutes == 0) return '항상 켜둠';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return [if (h > 0) '$h시간', if (m > 0) '$m분'].join(' ');
}

Map<String, dynamic> _catalogWithPowerOff() {
  final catalog = loadKovaCatalogFixture();
  (catalog['groups'] as List).add({
    'id': 'power',
    'order': 400,
    'title': {'ko': '전원', 'en': 'Power'},
    'description': {'ko': '콤마 전원 관련 설정입니다.', 'en': 'Comma power settings.'},
  });
  (catalog['settings'] as List).add({
    'key': _key,
    'groupId': 'power',
    'order': 100,
    'type': 'enum',
    'options': _options,
    'optionTitles': {
      for (final m in _options) '$m': {'ko': _title(m), 'en': '$m min'},
    },
    'defaultValue': 1440,
    'title': {'ko': '자동 전원 끄기', 'en': 'Automatic power off'},
    'description': {
      'ko': '시동을 끈 뒤 이 시간이 지나면 콤마가 꺼집니다.',
      'en': 'The comma powers off this long after the vehicle is switched off.',
    },
    'access': 'readWrite',
    'risk': 'behavior',
    'applyPolicy': 'immediate',
    'savePolicy': 'anytime',
    'availability': 'available',
  });
  return catalog;
}

Future<void> _pump(WidgetTester tester, KovaParamsController kova) async {
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
  await tester.tap(find.byKey(const PageStorageKey('kova-group-panel-power')));
  await tester.pumpAndSettle();
}

void main() {
  late FakeKovaGateway gateway;
  late KovaParamsController kova;

  setUp(() {
    gateway = FakeKovaGateway(catalog: _catalogWithPowerOff(), offroad: false);
    kova = KovaParamsController(
      clientFactory: (endpoint, onError) => KovaParamsClient.tryCreate(
        endpoint,
        transport: gateway,
        onError: onError,
      ),
      pollInterval: null,
    );
  });

  tearDown(() => kova.dispose());

  testWidgets(
    'shows the current power-off time and picks from the scrolling list',
    (tester) async {
      await kova.connect('http://127.0.0.1:18082');
      await _pump(tester, kova);
      expect(find.text('자동 전원 끄기'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('kova-value-$_key')))
            .data,
        '24시간',
      );

      await tester.tap(find.byKey(const ValueKey('kova-choice-$_key')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('kova-option-$_key-0')), findsOneWidget);
      expect(find.text('항상 켜둠'), findsOneWidget);

      final target = find.byKey(const ValueKey('kova-option-$_key-1410'));
      await tester.scrollUntilVisible(
        target,
        300,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('kova-options-$_key')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('kova-confirm-change')), findsNothing);
      expect(gateway.posts.single['value'], isA<int>());
      expect(gateway.posts.single['value'], 1410);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('kova-value-$_key')))
            .data,
        '23시간 30분',
      );
    },
  );

  testWidgets('always on is the first choice and is saved while driving', (
    tester,
  ) async {
    await kova.connect('http://127.0.0.1:18082');
    await _pump(tester, kova);
    await tester.tap(find.byKey(const ValueKey('kova-choice-$_key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kova-option-$_key-0')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(gateway.posts.single['value'], 0);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('kova-value-$_key'))).data,
      '항상 켜둠',
    );
  });

  testWidgets('short option lists still look the same', (tester) async {
    await kova.connect('http://127.0.0.1:18082');
    await _pump(tester, kova);
    await tester.tap(find.byKey(const PageStorageKey('kova-group-panel-e2e')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kova-choice-e2e.mode')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('kova-option-e2e.mode-lively')),
      findsOneWidget,
    );
  });
}
