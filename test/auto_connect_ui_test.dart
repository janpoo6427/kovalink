import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/features/connect/connect_screen.dart';
import 'package:kovalink/src/features/road_view/hud/drive_hud.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/app_auto_connect_target.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';

import 'support/fake_auto_connect.dart';

final _wifi = LocalNetwork.named('wlan0', '192.168.0.23');
final _cell = LocalNetwork.named('rmnet_data0', '10.20.30.40');

Future<void> _settle(WidgetTester tester, [Duration? by]) async {
  await tester.pump(by);
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
}

void main() {
  group('settings', () {
    test('자동 연결 is on by default and round-trips', () {
      expect(const AppSettings().autoConnect, isTrue);
      expect(const AppSettings().lastDeviceEndpoint, isNull);
      const s = AppSettings(
        autoConnect: false,
        lastDeviceEndpoint: 'http://192.168.0.40:8082',
      );
      final restored = AppSettings.fromJson(s.toJson());
      expect(restored, s);
      expect(AppSettings.fromJson(const {}).autoConnect, isTrue);
    });

    test('a stored public last-device address is dropped', () {
      for (final bad in [
        'http://203.0.113.9:8082',
        'http://example.com:8082',
        'http://192.168.0.40:8082/v1/health',
        'ws://192.168.0.40:8082',
      ]) {
        expect(
          AppSettings.fromJson({'lastDeviceEndpoint': bad}).lastDeviceEndpoint,
          isNull,
          reason: bad,
        );
      }
    });

    test('rememberDevice moves all three addresses to the device', () async {
      final store = MemorySettingsStore();
      final settings = SettingsController(store: store);
      expect(settings.rememberDevice('192.168.0.40', 8082), isNull);
      final v = settings.value;
      expect(v.lastDeviceEndpoint, 'http://192.168.0.40:8082');
      expect(v.settingsEndpoint, 'http://192.168.0.40:8082');
      expect(v.telemetryEndpoint, 'ws://192.168.0.40:8082/v1/telemetry');
      expect(v.signalingEndpoint, 'http://192.168.0.40:8082/v1/stream');
      await Future<void>.delayed(Duration.zero);
      expect(store.data!['lastDeviceEndpoint'], 'http://192.168.0.40:8082');
      settings.dispose();
    });

    test('rememberDevice refuses a public host', () {
      final settings = SettingsController(store: MemorySettingsStore());
      expect(settings.rememberDevice('203.0.113.9', 8082), isNotNull);
      expect(settings.value, const AppSettings());
      settings.dispose();
    });
  });

  group('GatewayController.connectInBackground', () {
    test('a refused socket keeps the demo and shows no error', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final gateway = GatewayController()..startDemo();
      final live = await gateway.connectInBackground(
        'ws://127.0.0.1:$port/v1/telemetry',
      );
      expect(live, isFalse);
      expect(gateway.mode, GatewayMode.demo);
      expect(gateway.errorMessage, isNull);
      gateway.dispose();
    });

    test('a public address is never opened', () async {
      var opened = 0;
      final gateway = GatewayController(
        webSocketConnector: (url) async {
          opened++;
          throw const SocketException('no');
        },
      );
      expect(
        await gateway.connectInBackground('ws://203.0.113.9:8082/v1/telemetry'),
        isFalse,
      );
      expect(opened, 0);
      gateway.dispose();
    });

    test('an open telemetry socket goes live', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final ws = await WebSocketTransformer.upgrade(request);
        ws.add('{"speedMps": 10}');
      });
      final gateway = GatewayController()..startDemo();
      final live = await gateway.connectInBackground(
        'ws://127.0.0.1:${server.port}/v1/telemetry',
      );
      expect(live, isTrue);
      expect(gateway.mode, GatewayMode.live);
      expect(gateway.scenario, isNull);
      gateway.dispose();
      await server.close(force: true);
    });
  });

  group('connect screen', () {
    testWidgets('shows networks, progress, devices and the activity log', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final probe = FakeProbe()
        ..device('192.168.0.40')
        ..device('192.168.0.41')
        ..other('192.168.0.30');
      final target = FakeTarget();
      final settings = SettingsController(store: MemorySettingsStore());
      final auto = AutoConnectController(
        target: target,
        probe: probe,
        listNetworks: () async => [_wifi, _cell],
      );
      final gateway = GatewayController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectScreen(
              controller: gateway,
              settings: settings,
              autoConnect: auto,
            ),
          ),
        ),
      );
      expect(find.text('자동 연결 꺼짐'), findsOneWidget);
      auto.setEnabled(true);
      await _settle(tester);
      expect(find.text('와이파이'), findsOneWidget);
      expect(find.text('192.168.0.23'), findsOneWidget);
      expect(find.text('모바일 데이터'), findsOneWidget);
      expect(find.text('안 찾아요'), findsOneWidget);
      expect(find.text('콤마 2대 찾음'), findsOneWidget);
      expect(find.text('콤마 · 192.168.0.40'), findsOneWidget);
      expect(find.text('콤마 · 192.168.0.41'), findsOneWidget);
      expect(find.textContaining('192.168.0.30 · 콤마가 아니에요'), findsOneWidget);
      expect(find.textContaining('192.168.0.x에서 252곳을 찾아봐요'), findsOneWidget);
      // No developer words on the panel.
      final panel = find.byKey(const ValueKey('auto-connect-panel'));
      for (final word in ['gateway', '/v1/', 'health', 'HTTP', 'JSON', '/24']) {
        expect(
          find.descendant(of: panel, matching: find.textContaining(word)),
          findsNothing,
          reason: word,
        );
      }

      await tester.tap(
        find.byKey(const ValueKey('auto-connect-choose-192.168.0.41:8082')),
      );
      await _settle(tester);
      expect(find.text('콤마 연결됨'), findsOneWidget);
      expect(target.attached.single.host, '192.168.0.41');
      expect(find.text('연결됨'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('auto-connect-switch')));
      await _settle(tester);
      expect(settings.value.autoConnect, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      auto.dispose();
      gateway.dispose();
      settings.dispose();
    });

    testWidgets('search progress is shown while scanning', (tester) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final probe = FakeProbe()..delay = const Duration(milliseconds: 200);
      final auto = AutoConnectController(
        target: FakeTarget(),
        probe: probe,
        listNetworks: () async => [_wifi],
        concurrency: 8,
      );
      final gateway = GatewayController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectScreen(controller: gateway, autoConnect: auto),
          ),
        ),
      );
      auto.setEnabled(true);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('콤마 찾는 중 · 1번째'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('auto-connect-progress')),
        findsOneWidget,
      );
      expect(find.textContaining('253곳 중'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      auto.dispose();
      gateway.dispose();
      // Let the in-flight fake probes finish.
      await tester.pump(const Duration(seconds: 1));
    });
  });

  testWidgets('settings screen switch turns 자동 연결 off', (tester) async {
    tester.view.physicalSize = const Size(900, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsController(store: MemorySettingsStore());
    final gateway = GatewayController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(controller: gateway, settings: settings),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('콤마 자동으로 찾기'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('setting-auto-connect')));
    await tester.pump();
    expect(settings.value.autoConnect, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    gateway.dispose();
    settings.dispose();
  });

  group('app wiring', () {
    late FakeProbe probe;
    AutoConnectController? built;

    Widget app(MemorySettingsStore store) => KovaLinkApp(
      settingsStore: store,
      storageRoot: () async => Directory.systemTemp,
      autoConnectBuilder: (target, settings) => built = AutoConnectController(
        target: target,
        probe: probe,
        listNetworks: () async => [_wifi, _cell],
        lastEndpoint: () => settings.value.lastDeviceEndpoint,
      ),
    );

    setUp(() {
      probe = FakeProbe();
      built = null;
    });

    testWidgets('finds the comma, saves it and shows 연결됨 on the road', (
      tester,
    ) async {
      probe.device('192.168.0.40');
      final store = MemorySettingsStore();
      await tester.pumpWidget(app(store));
      await _settle(tester);
      expect(built!.phase, AutoConnectPhase.connected);
      expect(find.byKey(const ValueKey('auto-connect-chip')), findsOneWidget);
      expect(find.text('콤마 연결됨'), findsOneWidget);
      await _settle(tester, const Duration(milliseconds: 50));
      expect(store.data!['lastDeviceEndpoint'], 'http://192.168.0.40:8082');
      // Only the found comma is saved; every address follows it.
      expect(store.data!.containsKey('telemetryEndpoint'), isFalse);
      // No telemetry socket on this device: the demo keeps playing, no error.
      expect(find.byType(TrafficLightGlyph), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('auto-connect-chip')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('auto-connect-panel')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      // In-flight settings/telemetry attempts time out (5 s) on their own.
      await _settle(tester, const Duration(seconds: 6));
    });

    testWidgets("재연결 안내는 작은 화면에서도 카메라 버튼을 가리지 않는다", (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(MemorySettingsStore()));
      await _settle(tester);
      expect(built!.phase, AutoConnectPhase.waiting);
      final status = find.byKey(const ValueKey("auto-connect-chip"));
      final camera = find.byTooltip("카메라 화면으로 바꾸기");
      expect(tester.getRect(status).overlaps(tester.getRect(camera)), isFalse);
      await tester.tap(camera);
      await _settle(tester);
      expect(find.byTooltip("카메라에 도로 겹쳐 보기"), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester, const Duration(seconds: 6));
    });
    testWidgets('stored 자동 연결 off: no probe is ever sent', (tester) async {
      probe.device('192.168.0.40');
      await tester.pumpWidget(app(MemorySettingsStore({'autoConnect': false})));
      await _settle(tester, const Duration(seconds: 30));
      expect(probe.calls, isEmpty);
      expect(find.text('자동 연결 꺼짐'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      // In-flight settings/telemetry attempts time out (5 s) on their own.
      await _settle(tester, const Duration(seconds: 6));
    });

    testWidgets('app paused → no probes; resumed → search again', (
      tester,
    ) async {
      await tester.pumpWidget(app(MemorySettingsStore()));
      await _settle(tester);
      expect(built!.phase, AutoConnectPhase.waiting);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _settle(tester);
      expect(built!.phase, AutoConnectPhase.paused);
      final calls = probe.calls.length;
      await _settle(tester, const Duration(minutes: 2));
      expect(probe.calls.length, calls);
      probe.device('192.168.0.40');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(built!.phase, AutoConnectPhase.connected);
      await tester.pumpWidget(const SizedBox.shrink());
      // In-flight settings/telemetry attempts time out (5 s) on their own.
      await _settle(tester, const Duration(seconds: 6));
    });
  });

  group('telemetry watch (real loopback socket)', () {
    test('데모 보기 holds telemetry; 지금 찾기 and a lost socket reopen it', () async {
      var opened = 0;
      final sockets = <WebSocket>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path != '/v1/telemetry') {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        opened++;
        sockets.add(await WebSocketTransformer.upgrade(request));
      });
      final port = server.port;
      final probe = FakeProbe()..device('127.0.0.1', port);
      final settings = SettingsController(store: MemorySettingsStore());
      final gateway = GatewayController()..startDemo();
      final kova = KovaParamsController(pollInterval: null);
      final auto = AutoConnectController(
        target: AppAutoConnectTarget(
          controller: gateway,
          settings: settings,
          kovaParams: kova,
        ),
        probe: probe,
        listNetworks: () async => const [],
        lastEndpoint: () => 'http://127.0.0.1:$port',
        ports: [port],
        heartbeatInterval: const Duration(milliseconds: 200),
        networkWatchInterval: const Duration(minutes: 1),
      );
      final watch = TelemetryWatch(controller: gateway, autoConnect: auto);
      addTearDown(() async {
        watch.dispose();
        auto.dispose();
        kova.dispose();
        gateway.dispose();
        settings.dispose();
        await server.close(force: true);
      });

      Future<void> until(bool Function() ok, String what) async {
        for (var i = 0; i < 100 && !ok(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(ok(), isTrue, reason: what);
      }

      auto.setEnabled(true);
      await until(() => gateway.mode == GatewayMode.live, 'first live');
      expect(opened, 1);
      expect(gateway.connectedEndpoint, 'ws://127.0.0.1:$port/v1/telemetry');

      // 데모 보기 while live: the demo stays, telemetry is not reopened.
      gateway.startDemo();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(gateway.mode, GatewayMode.demo);
      expect(opened, 1);
      expect(auto.phase, AutoConnectPhase.connected);
      expect(auto.telemetryHeld, isTrue);

      // 지금 찾기 reopens it.
      auto.retryNow();
      await until(() => gateway.mode == GatewayMode.live, 'live after retry');
      expect(opened, 2);

      // The comma drops the socket: lost, not held, so it comes back.
      await until(() => sockets.length == 2, 'second socket');
      await sockets.last.close();
      await until(() => opened == 3, 'reopened after the drop');
      await until(() => gateway.mode == GatewayMode.live, 'live again');
      expect(auto.telemetryHeld, isFalse);
      expect(probe.violations, isEmpty);
    });
  });

  testWidgets('flutter test never scans real interfaces by default', (
    tester,
  ) async {
    // KovaLinkApp() without a builder starts no real search under
    // `flutter test`: no chip, no controller.
    expect(Platform.environment.containsKey('FLUTTER_TEST'), isTrue);
    await tester.pumpWidget(
      KovaLinkApp(
        settingsStore: MemorySettingsStore(),
        storageRoot: () async => Directory.systemTemp,
      ),
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('auto-connect-chip')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester, const Duration(seconds: 6));
  });
}
