// 자동 연결 end to end against a real kovapilot gateway process.
//
// Skipped unless KOVA_E2E_GATEWAY_HOOK points at the hook script (see
// test/kovapilot_gateway_e2e_test.dart and tool/e2e/kovapilot_gateway_hook.sh).
//
// The gateway binds 127.0.0.1:$KOVA_E2E_PORT only. The test pretends the
// phone sits on Wi-Fi 127.0.0.5/24 (plus a mobile-data interface that must
// never be scanned) and puts plain TCP forwarders on 127.0.0.77 / .78 that
// relay to the gateway, so the device can only be found by scanning the /24
// with real sockets and confirming the real `/v1/health` answer. Decoys on
// .7 (another web server) and .9 (accepts, never answers) must be rejected.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/app_auto_connect_target.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';

final String? _hook = Platform.environment['KOVA_E2E_GATEWAY_HOOK'];
// Own gateway port and state (KOVA_E2E_PORT + 7) so this file can run in the
// same `flutter test` as kovapilot_gateway_e2e_test.dart.
final int _gatewayPort =
    (int.tryParse(Platform.environment['KOVA_E2E_PORT'] ?? '') ?? 18082) + 7;
final int _scanPort = _gatewayPort + 1000;

Future<void> hook(List<String> args) async {
  final state = Platform.environment['KOVA_E2E_STATE'];
  final result = await Process.run(
    'bash',
    [_hook!, ...args],
    environment: {
      'KOVA_E2E_PORT': '$_gatewayPort',
      if (state != null) 'KOVA_E2E_STATE': '$state-autoconnect',
    },
  );
  if (result.exitCode != 0) {
    fail(
      'hook ${args.join(' ')} failed (${result.exitCode}): ${result.stdout}\n${result.stderr}',
    );
  }
}

class RecordingProbe implements DeviceProbe {
  RecordingProbe(this.inner);
  final DeviceProbe inner;
  final calls = <String>[];

  @override
  Future<ProbeResult> probe(String host, int port) {
    calls.add('$host:$port');
    return inner.probe(host, port);
  }

  @override
  void close() => inner.close();
}

/// Transparent TCP relay host:_scanPort → 127.0.0.1:_gatewayPort.
Future<ServerSocket> relay(String host) async {
  final server = await ServerSocket.bind(host, _scanPort);
  server.listen((client) async {
    try {
      final up = await Socket.connect(
        '127.0.0.1',
        _gatewayPort,
        timeout: const Duration(seconds: 1),
      );
      client.listen(
        up.add,
        onDone: () => up.destroy(),
        onError: (Object _) => up.destroy(),
      );
      up.listen(
        client.add,
        onDone: () => client.destroy(),
        onError: (Object _) => client.destroy(),
      );
    } on Object {
      client.destroy();
    }
  });
  return server;
}

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  String? what,
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      fail('timed out waiting for ${what ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

class _Rig {
  _Rig() {
    target = AppAutoConnectTarget(
      controller: gateway,
      settings: settings,
      kovaParams: kova,
    );
    auto = AutoConnectController(
      target: target,
      probe: probe,
      listNetworks: () async => [
        LocalNetwork.named('wlan0', '127.0.0.5'),
        LocalNetwork.named('rmnet_data0', '127.0.1.5'),
      ],
      lastEndpoint: () => settings.value.lastDeviceEndpoint,
      ports: [_scanPort],
      heartbeatInterval: const Duration(seconds: 1),
      networkWatchInterval: const Duration(seconds: 1),
    );
  }

  final settings = SettingsController(store: MemorySettingsStore());
  final gateway = GatewayController()..startDemo();
  final kova = KovaParamsController(
    clientFactory: (endpoint, onError) => KovaParamsClient.tryCreate(
      endpoint,
      timeout: const Duration(seconds: 3),
      onError: onError,
    ),
    pollInterval: null,
  );
  final probe = RecordingProbe(HttpDeviceProbe());
  late final AppAutoConnectTarget target;
  late final AutoConnectController auto;

  List<String> get log => auto.log.map((e) => e.message).toList();

  void dispose() {
    auto.dispose();
    kova.dispose();
    gateway.dispose();
    settings.dispose();
  }
}

void main() {
  final skip = _hook == null
      ? 'KOVA_E2E_GATEWAY_HOOK not set (real gateway e2e)'
      : null;

  group('auto-connect against python -m openpilot.kovapilot.gateway', () {
    final servers = <Object>[];
    final held = <Socket>[];

    setUpAll(() async {
      await hook(['reset']);
      await hook(['start', 'bundled']);
      // Decoy 1: another web server on the same port.
      final web = await HttpServer.bind('127.0.0.7', _scanPort);
      web.listen((request) {
        request.response
          ..headers.contentType = ContentType.json
          ..write('{"status":"fine","schemaVersion":1}')
          ..close();
      });
      // Decoy 2: accepts the connection and never answers.
      final silent = await ServerSocket.bind('127.0.0.9', _scanPort);
      silent.listen(held.add);
      servers
        ..add(web)
        ..add(silent);
    });

    tearDownAll(() async {
      for (final s in held) {
        s.destroy();
      }
      for (final s in servers) {
        if (s is HttpServer) await s.close(force: true);
        if (s is ServerSocket) await s.close();
      }
      await hook(['stop']);
    });

    test(
      'scans the /24, confirms the gateway, connects, follows a restart',
      () async {
        final device = await relay('127.0.0.77');
        final rig = _Rig();
        addTearDown(() async {
          rig.dispose();
          await device.close();
        });
        final watch = Stopwatch()..start();
        rig.auto.setEnabled(true);
        await waitFor(
          () => rig.auto.phase == AutoConnectPhase.connected,
          what: 'first connection',
        );
        final firstScan = watch.elapsed;
        final firstProbes = rig.probe.calls.length;
        expect(rig.auto.device!.label, '127.0.0.77:$_scanPort');
        // The whole /24 of the Wi-Fi interface was probed; mobile data never.
        expect(rig.probe.calls.toSet(), hasLength(253));
        expect(rig.probe.calls.where((c) => c.startsWith('127.0.1.')), isEmpty);
        expect(rig.log, contains('127.0.0.7:$_scanPort · 콤마가 아니에요'));
        expect(
          rig.log.where((l) => l.startsWith('127.0.0.9:$_scanPort · 콤마가 아니에요')),
          hasLength(1),
        );
        expect(
          rig.settings.value.lastDeviceEndpoint,
          'http://127.0.0.77:$_scanPort',
        );
        expect(
          rig.settings.value.settingsEndpoint,
          'http://127.0.0.77:$_scanPort',
        );
        expect(
          rig.settings.value.telemetryEndpoint,
          'ws://127.0.0.77:$_scanPort/v1/telemetry',
        );

        // kovapilot settings opened through the found address.
        await waitFor(
          () => rig.kova.status == KovaLinkStatus.connected,
          what: 'kova_params document',
        );
        expect(rig.kova.endpoint, 'http://127.0.0.77:$_scanPort');
        expect(rig.kova.document!.settings, isNotEmpty);
        expect(rig.kova.health!.bindScope, 'loopback');
        // This gateway has no telemetry socket yet: demo stays, no error.
        expect(rig.gateway.mode, GatewayMode.demo);
        expect(rig.gateway.errorMessage, isNull);

        // Gateway stops → heartbeat misses twice → searching again.
        await hook(['stop']);
        await waitFor(
          () => rig.auto.device == null,
          timeout: const Duration(seconds: 15),
          what: 'loss detection',
        );
        expect(rig.log, contains('콤마와 연결이 끊겼어요. 다시 찾아요.'));
        expect(rig.auto.phase, isNot(AutoConnectPhase.connected));

        // Gateway back → found again, last address first.
        await hook(['start', 'bundled']);
        final before = rig.probe.calls.length;
        final back = Stopwatch()..start();
        await waitFor(
          () => rig.auto.phase == AutoConnectPhase.connected,
          timeout: const Duration(seconds: 45),
          what: 'reconnection',
        );
        expect(rig.auto.device!.label, '127.0.0.77:$_scanPort');
        expect(
          rig.log.last,
          startsWith('콤마 127.0.0.77:$_scanPort에 연결했어요 (마지막 주소)'),
        );
        expect(rig.probe.calls.skip(before), contains('127.0.0.77:$_scanPort'));
        // ignore: avoid_print
        print(
          'e2e: first connection ${firstScan.inMilliseconds} ms / $firstProbes probes; '
          'reconnect ${back.elapsed.inMilliseconds} ms after gateway start',
        );
      },
    );

    test('two devices are listed and the chosen one connects', () async {
      final a = await relay('127.0.0.77');
      final b = await relay('127.0.0.78');
      final rig = _Rig();
      addTearDown(() async {
        rig.dispose();
        await a.close();
        await b.close();
      });
      rig.auto.setEnabled(true);
      await waitFor(
        () => rig.auto.phase == AutoConnectPhase.choosing,
        what: 'device list',
      );
      expect(rig.auto.found.map((d) => d.label), [
        '127.0.0.77:$_scanPort',
        '127.0.0.78:$_scanPort',
      ]);
      expect(rig.settings.value.lastDeviceEndpoint, isNull);
      await rig.auto.choose(rig.auto.found[1]);
      await waitFor(
        () => rig.kova.status == KovaLinkStatus.connected,
        what: 'kova_params via the chosen device',
      );
      expect(rig.kova.endpoint, 'http://127.0.0.78:$_scanPort');
      expect(
        rig.settings.value.lastDeviceEndpoint,
        'http://127.0.0.78:$_scanPort',
      );
    });

    test('자동 연결 off sends nothing', () async {
      final a = await relay('127.0.0.77');
      final rig = _Rig();
      addTearDown(() async {
        rig.dispose();
        await a.close();
      });
      rig.auto.setEnabled(true);
      rig.auto.setEnabled(false);
      final calls = rig.probe.calls.length;
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(rig.probe.calls.length, calls);
      expect(rig.auto.phase, AutoConnectPhase.off);
    });
  }, skip: skip);
}
