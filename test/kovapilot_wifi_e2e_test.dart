// End-to-end test of the Wi-Fi connection against the real kovapilot gateway
// (master-jh b476713a7 or later: TLS on wlan0's private IPv4, Bearer token,
// same /24 only, Host must be the IP, Origin refused, re-bind on IP change).
//
// Skipped unless KOVA_E2E_WIFI_HOOK points at
// tool/e2e/kovapilot_wifi_gateway_hook.sh, which runs
// `python -m openpilot.kovapilot.gateway` in the kovapilot dev container on
// its own Docker network with the container interface renamed to wlan0.
// This test process is the phone on the same /24. Run:
//
//   KOVAPILOT_DIR=~/kova/wt/kp-wifi-e2e \
//   KOVA_E2E_WIFI_SECRETS=<dir with server.pem server.key token.sha256 token pin_spki_sha256.hex> \
//   KOVA_E2E_WIFI_HOOK=tool/e2e/kovapilot_wifi_gateway_hook.sh \
//   flutter test test/kovapilot_wifi_e2e_test.dart
//
// The credential directory is outside the repository; the token is read
// from it at run time and never printed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/kovapilot_git/git_client.dart';
import 'package:kovalink/src/network/comma_link_text.dart';
import 'package:kovalink/src/network/comma_registry.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/gateway_pin.dart';
import 'package:kovalink/src/network/gateway_session.dart';
import 'package:kovalink/src/network/kovapilot_endpoints.dart';
import 'package:kovalink/src/services/app_auto_connect_target.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/comma_link.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/web_rtc_road_stream.dart';
import 'package:kovalink/src/settings/app_settings.dart';

import 'support/fake_wifi_gateway.dart' show pinDeviceA;

final String? _hook = Platform.environment['KOVA_E2E_WIFI_HOOK'];
final String? _secrets = Platform.environment['KOVA_E2E_WIFI_SECRETS'];
const _port = 8082;

Future<String> hook(List<String> args) async {
  final result = await Process.run('bash', [_hook!, ...args]);
  if (result.exitCode != 0) {
    fail(
      'hook ${args.join(' ')} failed (${result.exitCode}): ${result.stdout}\n${result.stderr}',
    );
  }
  return (result.stdout as String).trim().split('\n').last.trim();
}

Future<void> until(bool Function() ok, String what, {int seconds = 30}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(ok(), isTrue, reason: what);
}

void main() {
  final skip = _hook == null || _secrets == null
      ? 'KOVA_E2E_WIFI_HOOK / KOVA_E2E_WIFI_SECRETS not set (real Wi-Fi gateway e2e)'
      : null;

  late String commaIp;
  late String phoneIp;
  late GatewayPin pin;
  late String token;
  late String wrongToken;
  late SettingsController settings;
  late MemoryCommaTokenStore tokens;
  late CommaLink link;

  setUpAll(() async {
    if (skip != null) return;
    pin = GatewayPin.fromHex(
      File('$_secrets/pin_spki_sha256.hex').readAsStringSync().trim(),
    )!;
    token = GatewayCredentials.normalizeToken(
      File('$_secrets/token').readAsStringSync(),
    )!;
    // Another well-formed token: flip the last digit.
    final last = token.substring(63) == '0' ? '1' : '0';
    wrongToken = token.substring(0, 63) + last;
    commaIp = await hook(['start']);
    phoneIp = await hook(['phone']);
  });
  tearDownAll(() async {
    if (skip == null) await hook(['stop']);
  });

  setUp(() {
    settings = SettingsController(store: MemorySettingsStore());
    tokens = MemoryCommaTokenStore();
    link = CommaLink(settings: settings, tokens: tokens);
  });
  tearDown(() {
    link.dispose();
    settings.dispose();
  });

  List<LocalNetwork> wifi() => [LocalNetwork.named('wlan0', phoneIp)];

  group('kovapilot gateway on Wi-Fi', skip: skip, () {
    test(
      '찾기: TLS without a token gets the 401 challenge and the pin',
      () async {
        final probe = GatewayDeviceProbe();
        addTearDown(probe.close);
        final result = await probe.probe(commaIp, _port);
        expect(result.outcome, ProbeOutcome.kova);
        final device = result.device!;
        expect(device.secure, isTrue);
        expect(device.pin, pin, reason: 'the pin of the certificate it showed');
        expect(device.settingsEndpoint, 'https://$commaIp:$_port');

        // The Finder over the whole /24: the comma is listed, not connected
        // (nothing is registered yet).
        final auto = AutoConnectController(
          target: _NoTarget(),
          listNetworks: () async => wifi(),
          canAttach: link.canAttach,
          networkWatchInterval: const Duration(minutes: 5),
        );
        addTearDown(auto.dispose);
        auto.setEnabled(true);
        await until(
          () => auto.phase == AutoConnectPhase.choosing,
          'listed after one pass, phase ${auto.phase}',
          seconds: 60,
        );
        expect(auto.found.map((d) => d.host), [commaIp]);
        expect(auto.found.single.pin, pin);
        expect(auto.problem, KovaLinkProblem.needsRegistration);
        expect(auto.device, isNull);
      },
    );

    test('등록: the right pin and token are checked, then saved', () async {
      expect(
        await link.register(host: commaIp, port: _port, pin: pin, token: token),
        isNull,
      );
      expect(settings.value.registeredComma?.pin, pin);
      expect(settings.value.registeredComma?.host, commaIp);
      expect(link.health?.bindScope, 'wifi');
      expect(link.health?.authentication, 'bearer');
      expect(await tokens.read(pin), token);
      expect(jsonEncode(settings.value.toJson()), isNot(contains(token)));
      expect(link.session?.sendsToken, isTrue);
    });

    test(
      '토큰 통과: settings (read and write), Git, telemetry and camera through the one session',
      () async {
        expect(
          await link.register(
            host: commaIp,
            port: _port,
            pin: pin,
            token: token,
          ),
          isNull,
        );
        final origin = 'https://$commaIp:$_port';
        final session = link.sessionFor(origin)!;

        final kova = KovaParamsController(
          pollInterval: null,
          sessionFor: link.sessionFor,
        );
        addTearDown(kova.dispose);
        expect(await kova.connect(origin), isNull);
        expect(kova.status, KovaLinkStatus.connected);
        expect(kova.isAuthenticatedSession, isTrue);
        expect(kova.writeLock, KovaWriteLock.none);
        final before = kova.document!.setting('steering.always_on')!.value;
        final outcome = await kova.setValue(
          'steering.always_on',
          before != true,
        );
        expect(outcome, isA<KovaUpdateApplied>());
        expect(
          kova.document!.setting('steering.always_on')!.value,
          before != true,
        );

        final git = KovaGitClient.tryCreate(
          origin,
          transport: session.transport,
        )!;
        final status = await git.status();
        expect(status.head, matches(RegExp(r'^[0-9a-f]{40}$')));
        expect(status.mutationEnabled, isFalse);

        final gateway = GatewayController();
        addTearDown(gateway.dispose);
        expect(
          await gateway.connectInBackground(
            KovapilotEndpoints.device(commaIp).telemetry,
            session: session,
          ),
          isTrue,
        );
        expect(gateway.mode, GatewayMode.live);
        expect(gateway.gatewayAuthenticated, isTrue);
        expect(gateway.connectedEndpoint, 'wss://$commaIp:$_port/v1/telemetry');

        // No webrtcd in the container: the gateway accepts the token and the
        // offer, then says the camera is not available (503), never 401/403.
        await expectLater(
          postKovapilotOffer(
            Uri.parse(KovapilotEndpoints.device(commaIp).signaling),
            sdp: 'v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n',
            camera: 'road',
            session: session,
            timeout: const Duration(seconds: 20),
          ),
          throwsA(
            isA<HttpException>().having(
              (e) => e.message,
              'message',
              allOf(contains('HTTP 503'), contains('camera_unavailable')),
            ),
          ),
        );
      },
    );

    test('토큰 거절: a wrong token is 401; nothing is saved', () async {
      expect(
        await link.register(
          host: commaIp,
          port: _port,
          pin: pin,
          token: wrongToken,
        ),
        KovaLinkProblem.tokenRejected,
      );
      expect(settings.value.registeredComma, isNull);
      expect(tokens.tokens, isEmpty);
      expect(link.session, isNull);

      // A registration whose token was changed on the comma: open() says so.
      await tokens.write(pin, wrongToken);
      unawaited(
        settings.update(
          (s) => s.copyWith(
            registeredComma: RegisteredComma(pin: pin, host: commaIp),
          ),
        ),
      );
      final device = KovaDevice(
        host: commaIp,
        port: _port,
        secure: true,
        pin: pin,
      );
      expect(await link.open(device), KovaLinkProblem.tokenRejected);
      expect(link.session, isNull);
    });

    test('핀 불일치: another pin is refused before the token is sent', () async {
      final other = GatewayPin.fromHex(pinDeviceA)!;
      expect(other, isNot(pin));
      final session = GatewaySession(
        endpoints: KovapilotEndpoints.device(commaIp),
        credentials: GatewayCredentials(pin: other, token: token),
      );
      addTearDown(session.close);
      final check = await link.check(session);
      expect(check.problem, KovaLinkProblem.identityMismatch);
      // The connection was closed right after the handshake: the comma
      // showed its own certificate, which is not the pin we hold.
      expect(session.lastPresented, pin);

      expect(
        await link.register(
          host: commaIp,
          port: _port,
          pin: other,
          token: token,
        ),
        KovaLinkProblem.identityMismatch,
      );
      expect(settings.value.registeredComma, isNull);
      expect(tokens.tokens, isEmpty);
    });

    test(
      '403: an Origin header or a name instead of the IP is refused; the Finder says so plainly',
      () async {
        Future<(int, String)> raw(Map<String, String> headers) async {
          final client = gatewayTlsClient(
            host: commaIp,
            port: _port,
            accept: pin.matches,
          );
          try {
            final request = await client.getUrl(
              Uri.parse('https://$commaIp:$_port/v1/health'),
            );
            headers.forEach(request.headers.set);
            final response = await request.close();
            return (response.statusCode, await utf8.decodeStream(response));
          } finally {
            client.close(force: true);
          }
        }

        final origin = await raw({'Origin': 'https://example.org'});
        expect(origin.$1, 403);
        expect(origin.$2, contains('wifi_client_required'));
        final named = await raw({'Host': 'kovapilot.local:$_port'});
        expect(named.$1, 403);
        final judged = judgeGatewayChallenge(
          commaIp,
          _port,
          named.$1,
          const [],
          named.$2,
          pin,
        );
        expect(judged.outcome, ProbeOutcome.refused);
        expect(
          KovaLinkText.message(KovaLinkProblem.notAllowed),
          '같은 네트워크에 있지 않거나, 콤마가 휴대폰 연결을 허용하지 않았어요.',
        );

        // Plain HTTP on the Wi-Fi address: nothing a phone could use.
        final plain = await HttpDeviceProbe().probe(commaIp, _port);
        expect(plain.outcome, isNot(ProbeOutcome.kova));
      },
    );

    test(
      'IP 바뀜: the registered comma is found again at its new IP and reconnected',
      () async {
        expect(
          await link.register(
            host: commaIp,
            port: _port,
            pin: pin,
            token: token,
          ),
          isNull,
        );
        final gateway = GatewayController()..startDemo();
        final kova = KovaParamsController(
          pollInterval: null,
          sessionFor: link.sessionFor,
        );
        final target = AppAutoConnectTarget(
          controller: gateway,
          settings: settings,
          kovaParams: kova,
          link: link,
        );
        final auto = AutoConnectController(
          target: target,
          listNetworks: () async => wifi(),
          lastEndpoint: () => settings.value.registeredComma?.endpoints.origin,
          canAttach: link.canAttach,
          heartbeatInterval: const Duration(milliseconds: 500),
          networkWatchInterval: const Duration(minutes: 5),
        );
        target.onProblem = auto.hold;
        final watch = TelemetryWatch(controller: gateway, autoConnect: auto);
        addTearDown(() {
          watch.dispose();
          auto.dispose();
          kova.dispose();
          gateway.dispose();
        });

        auto.setEnabled(true);
        await until(
          () =>
              auto.phase == AutoConnectPhase.connected &&
              gateway.mode == GatewayMode.live,
          'connected at the first IP',
        );
        expect(auto.device?.host, commaIp);
        expect(gateway.connectedEndpoint, 'wss://$commaIp:$_port/v1/telemetry');
        await until(
          () => kova.status == KovaLinkStatus.connected,
          'settings at the first IP',
        );

        final moved = await hook(['move', '31']);
        expect(moved, isNot(commaIp));
        await until(
          () =>
              auto.phase == AutoConnectPhase.connected &&
              auto.device?.host == moved &&
              gateway.mode == GatewayMode.live,
          'reconnected at $moved (phase ${auto.phase}, device ${auto.device})',
          seconds: 90,
        );
        expect(gateway.connectedEndpoint, 'wss://$moved:$_port/v1/telemetry');
        expect(gateway.gatewayAuthenticated, isTrue);
        expect(settings.value.registeredComma?.host, moved);
        expect(settings.value.registeredComma?.pin, pin);
        expect(settings.value.lastDeviceEndpoint, 'https://$moved:$_port');
        await until(
          () =>
              kova.status == KovaLinkStatus.connected &&
              kova.endpoint == 'https://$moved:$_port',
          'settings follow the new IP',
        );
        expect(kova.writeLock, KovaWriteLock.none);
        commaIp = moved;
      },
    );
  });
}

class _NoTarget implements AutoConnectTarget {
  @override
  bool get isTelemetryLive => false;

  @override
  Future<void> attach(KovaDevice device, {bool openTelemetry = true}) async =>
      fail('nothing is registered: no comma may be attached');

  @override
  Future<void> keepAlive(
    KovaDevice device, {
    bool openTelemetry = true,
  }) async {}

  @override
  void detach(KovaDevice device) {}
}
