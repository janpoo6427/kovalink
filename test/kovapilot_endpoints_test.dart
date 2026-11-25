// KovaLink only talks to kovapilot: every address comes from the comma
// found on the network or entered by IP (no address before that) and no
// address field is on the screen itself. Addresses saved by older versions
// are ignored and taken out of the settings file.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/connect/auto_connect_panel.dart';
import 'package:kovalink/src/features/connect/connect_screen.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/kovapilot_endpoints.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';

import 'support/fake_auto_connect.dart';

void main() {
  group('addresses', () {
    test('before a comma is found: no address at all', () {
      const settings = AppSettings();
      expect(settings.endpoints, isNull);
      expect(settings.settingsEndpoint, isNull);
      expect(settings.telemetryEndpoint, isNull);
      expect(settings.signalingEndpoint, isNull);
    });

    test('all three follow the comma 자동 연결 found', () {
      const settings = AppSettings(
        lastDeviceEndpoint: 'http://192.168.43.17:8082',
      );
      expect(settings.settingsEndpoint, 'http://192.168.43.17:8082');
      expect(
        settings.telemetryEndpoint,
        'ws://192.168.43.17:8082/v1/telemetry',
      );
      expect(settings.signalingEndpoint, 'http://192.168.43.17:8082/v1/stream');

      const v6 = AppSettings(lastDeviceEndpoint: 'http://[fd00::5]:8082');
      expect(v6.telemetryEndpoint, 'ws://[fd00::5]:8082/v1/telemetry');
      expect(v6.signalingEndpoint, 'http://[fd00::5]:8082/v1/stream');
    });

    test('a refused device address gives no address', () {
      for (final bad in ['http://203.0.113.9:8082', 'http://example.com']) {
        expect(KovapilotEndpoints.fromOrigin(bad), isNull, reason: bad);
      }
    });

    test('rememberDevice moves every address, nothing else is stored', () {
      final store = MemorySettingsStore();
      final controller = SettingsController(store: store);
      expect(controller.rememberDevice('10.0.0.7', 8082), isNull);
      expect(
        controller.value.telemetryEndpoint,
        'ws://10.0.0.7:8082/v1/telemetry',
      );
      final json = controller.value.toJson();
      for (final key in AppSettings.legacyEndpointKeys) {
        expect(json.containsKey(key), isFalse, reason: key);
      }
      expect(json['lastDeviceEndpoint'], 'http://10.0.0.7:8082');
      controller.dispose();
    });
  });

  group('addresses saved by older versions', () {
    test('are ignored and taken out of the settings file', () async {
      final store = MemorySettingsStore({
        'speedUnit': 'mph',
        'telemetryEndpoint': 'ws://192.168.0.99:9000/v1/telemetry',
        'signalingEndpoint': 'http://192.168.0.99:9000/v1/stream',
        'settingsEndpoint': 'http://192.168.0.99:9000',
      });
      final controller = SettingsController(store: store);
      await controller.load();
      expect(controller.value.speedUnit.name, 'mph');
      expect(controller.value.telemetryEndpoint, isNull);
      expect(controller.value.signalingEndpoint, isNull);
      expect(controller.value.settingsEndpoint, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, 1);
      for (final key in AppSettings.legacyEndpointKeys) {
        expect(store.data!.containsKey(key), isFalse, reason: key);
      }
      expect(store.data!['speedUnit'], 'mph');
      controller.dispose();
    });

    test('a file without them is not written again on start', () async {
      final store = MemorySettingsStore({
        'speedUnit': 'mph',
        'lastDeviceEndpoint': 'http://192.168.0.40:8082',
      });
      final controller = SettingsController(store: store);
      await controller.load();
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, 0);
      expect(
        controller.value.telemetryEndpoint,
        'ws://192.168.0.40:8082/v1/telemetry',
      );
      controller.dispose();
    });
  });

  group('no address field on screen', () {
    late GatewayController gateway;
    late SettingsController settings;

    setUp(() {
      gateway = GatewayController();
      settings = SettingsController(
        store: MemorySettingsStore(),
        initial: const AppSettings(
          lastDeviceEndpoint: 'http://192.168.0.40:8082',
        ),
      );
    });

    tearDown(() {
      gateway.dispose();
      settings.dispose();
    });

    Future<void> pump(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
      await tester.pump();
    }

    testWidgets('settings: no field in any tab, addresses shown as text', (
      tester,
    ) async {
      await pump(
        tester,
        SettingsScreen(controller: gateway, settings: settings),
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(EditableText), findsNothing);
      expect(find.text('연결 주소'), findsNothing);

      await tester.tap(find.text('연결 상태'));
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('ws://192.168.0.40:8082/v1/telemetry'), findsOneWidget);
      expect(find.text('http://192.168.0.40:8082/v1/stream'), findsOneWidget);
      expect(find.text('http://192.168.0.40:8082'), findsOneWidget);
      expect(find.text('주소는 앱 탭에서 바꿀 수 있어요.'), findsNothing);

      await tester.tap(find.text('kovapilot'));
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const ValueKey('kova-edit-address')), findsNothing);
      expect(find.byTooltip('주소 바꾸기'), findsNothing);
      expect(find.text('http://192.168.0.40:8082'), findsOneWidget);
      expect(find.byKey(const ValueKey('kova-connect')), findsOneWidget);
    });

    testWidgets('connect: found comma, status, 지금 찾기 and 데모 보기 only', (
      tester,
    ) async {
      final probe = FakeProbe()..device('192.168.0.40');
      final auto = AutoConnectController(
        target: FakeTarget(),
        probe: probe,
        listNetworks: () async => [LocalNetwork.named('wlan0', '192.168.0.23')],
        lastEndpoint: () => settings.value.lastDeviceEndpoint,
      );
      gateway.disconnect();
      await pump(
        tester,
        ConnectScreen(
          controller: gateway,
          settings: settings,
          autoConnect: auto,
        ),
      );
      auto.setEnabled(true);
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      expect(auto.phase, AutoConnectPhase.connected);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(EditableText), findsNothing);
      expect(find.text('주소'), findsNothing);
      expect(find.textContaining('192.168.0.40'), findsWidgets);
      expect(find.text('지금 찾기'), findsOneWidget);
      expect(find.byKey(const ValueKey('auto-connect-status')), findsOneWidget);
      expect(find.text('카메라 켜기'), findsOneWidget);
      expect(find.textContaining('입력한 주소'), findsNothing);

      expect(gateway.mode, GatewayMode.disconnected);
      await tester.tap(find.byKey(const ValueKey('connect-demo')));
      await tester.pump();
      expect(gateway.mode, GatewayMode.demo);
      gateway.stopDemo();
      await tester.pumpWidget(const SizedBox.shrink());
      auto.dispose();
    });

    testWidgets('자동 연결 off says how to connect, not to type an address', (
      tester,
    ) async {
      final auto = AutoConnectController(
        target: FakeTarget(),
        probe: FakeProbe(),
        listNetworks: () async => const [],
      );
      await pump(
        tester,
        AutoConnectPanel(controller: auto, settings: settings),
      );
      expect(auto.phase, AutoConnectPhase.off);
      expect(find.textContaining('직접 넣어'), findsNothing);
      expect(find.textContaining('켜면 같은 와이파이나 핫스팟에서 콤마를 찾아'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      auto.dispose();
    });
  });
}
