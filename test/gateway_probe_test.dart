// The Finder's probe: a comma on Wi-Fi is the kovapilot 401 Bearer
// challenge over TLS, asked without a token; its certificate pin is kept.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/kovapilot_endpoints.dart';

import 'support/fake_wifi_gateway.dart';

const _challenge =
    '{"error": {"code": "authentication_required", "message": "valid Gateway credentials are required"}}';

void main() {
  group('judging an answer without a token', () {
    final pin = fixturePin(pinDeviceA);

    test('401 authentication_required with a Bearer challenge: a comma', () {
      final r = judgeGatewayChallenge(
        '192.168.43.20',
        8082,
        401,
        ['Bearer'],
        _challenge,
        pin,
      );
      expect(r.outcome, ProbeOutcome.kova);
      expect(r.device!.secure, isTrue);
      expect(r.device!.pin, pin);
      expect(r.device!.settingsEndpoint, 'https://192.168.43.20:8082');
      expect(
        judgeGatewayChallenge(
          'h',
          1,
          401,
          ['bearer realm="x"'],
          _challenge,
          pin,
        ).outcome,
        ProbeOutcome.kova,
      );
    });

    test('anything else is not a comma', () {
      for (final (status, challenges, body) in [
        (401, <String>[], _challenge),
        (401, ['Basic realm="router"'], _challenge),
        (401, ['Bearer'], '{"error": {"code": "other"}}'),
        (401, ['Bearer'], '<html>login</html>'),
        (200, <String>[], '{"status": "ok", "schemaVersion": 1}'),
        (404, <String>[], '{}'),
      ]) {
        expect(
          judgeGatewayChallenge('h', 1, status, challenges, body, pin).outcome,
          ProbeOutcome.notKova,
          reason: '$status $challenges $body',
        );
      }
      expect(
        judgeGatewayChallenge(
          'h',
          1,
          401,
          ['Bearer'],
          _challenge,
          null,
        ).outcome,
        ProbeOutcome.notKova,
        reason: 'no readable certificate',
      );
    });

    test('403 wifi_client_required: a comma that refuses this phone', () {
      final r = judgeGatewayChallenge(
        'h',
        1,
        403,
        [],
        '{"error": {"code": "wifi_client_required", "message": "x"}}',
        pin,
      );
      expect(r.outcome, ProbeOutcome.refused);
      expect(r.device, isNull);
      expect(r.refusing!.pin, pin);
    });
  });

  group('real sockets on 127.0.0.2', () {
    late GatewayDeviceProbe probe;
    setUp(() => probe = GatewayDeviceProbe());
    tearDown(() => probe.close());

    test(
      'a kovapilot Wi-Fi gateway is found, its pin recorded, no token sent',
      () async {
        final gateway = await FakeWifiGateway.start();
        addTearDown(gateway.close);
        final r = await probe.probe('127.0.0.2', gateway.port);
        expect(r.outcome, ProbeOutcome.kova);
        expect(r.device!.pin!.hex, pinDeviceA);
        expect(r.device!.host, '127.0.0.2');
        expect(gateway.requests.single.path, '/v1/health');
        expect(gateway.requests.single.authorization, isNull);
      },
    );

    test('a TLS server that answers without a token is not a comma', () async {
      final server = await HttpServer.bindSecure(
        '127.0.0.2',
        0,
        fixtureServerContext('device_b'),
      );
      server.listen((request) {
        request.response
          ..headers.contentType = ContentType.json
          ..write('{"status": "ok", "schemaVersion": 1}')
          ..close();
      });
      addTearDown(() => server.close(force: true));
      final r = await probe.probe('127.0.0.2', server.port);
      expect(r.outcome, ProbeOutcome.notKova);
    });

    test('a plain HTTP server is not a comma on Wi-Fi', () async {
      final server = await HttpServer.bind('127.0.0.2', 0);
      server.listen((request) {
        request.response
          ..statusCode = 401
          ..headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer')
          ..write(_challenge)
          ..close();
      });
      addTearDown(() => server.close(force: true));
      final r = await probe.probe('127.0.0.2', server.port);
      expect(r.outcome, ProbeOutcome.notKova);
    });

    test('nothing listening: no answer', () async {
      final socket = await ServerSocket.bind('127.0.0.2', 0);
      final port = socket.port;
      await socket.close();
      expect(
        (await probe.probe('127.0.0.2', port)).outcome,
        ProbeOutcome.noAnswer,
      );
    });

    test('a port that accepts but never answers: found, no answer', () async {
      final server = await ServerSocket.bind('127.0.0.2', 0);
      final held = <Socket>[];
      server.listen(held.add);
      addTearDown(() async {
        for (final s in held) {
          s.destroy();
        }
        await server.close();
      });
      // The connect itself is instant on loopback; a roomy connect timeout
      // keeps a busy machine from mistaking it for nobody there. Only the
      // missing TLS answer is under test.
      final quick = GatewayDeviceProbe(
        connectTimeout: const Duration(seconds: 2),
        responseTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(quick.close);
      final r = await quick.probe('127.0.0.2', server.port);
      expect(r.outcome, ProbeOutcome.notKova);
      expect(r.silent, isTrue);
    });

    test('public addresses are never probed', () async {
      expect(
        (await probe.probe('8.8.8.8', 8082)).outcome,
        ProbeOutcome.noAnswer,
      );
    });
  });

  group('addresses from one comma', () {
    test('Wi-Fi: https and wss on the IP', () {
      final e = KovapilotEndpoints.device('192.168.43.20');
      expect(e.secure, isTrue);
      expect(e.origin, 'https://192.168.43.20:8082');
      expect(e.settings, 'https://192.168.43.20:8082');
      expect(e.telemetry, 'wss://192.168.43.20:8082/v1/telemetry');
      expect(e.signaling, 'https://192.168.43.20:8082/v1/stream');
      expect(e.health.toString(), 'https://192.168.43.20:8082/v1/health');
      expect(
        e.kovaParams.toString(),
        'https://192.168.43.20:8082/v1/kova-params',
      );
      expect(
        e.kovaParamsUpdate.toString(),
        'https://192.168.43.20:8082/v1/kova-params/update',
      );
      expect(
        e.git('log', {'limit': '20'}).toString(),
        'https://192.168.43.20:8082/v1/git/log?limit=20',
      );
      expect(e.displayName, '192.168.43.20');
    });

    test('loopback: plain http and ws', () {
      final e = KovapilotEndpoints.device('127.0.0.1');
      expect(e.secure, isFalse);
      expect(e.origin, 'http://127.0.0.1:8082');
      expect(e.telemetry, 'ws://127.0.0.1:8082/v1/telemetry');
    });

    test('a stored origin keeps its scheme; refused ones give nothing', () {
      expect(
        KovapilotEndpoints.fromOrigin('https://10.0.0.7:8082')!.telemetry,
        'wss://10.0.0.7:8082/v1/telemetry',
      );
      expect(
        KovapilotEndpoints.fromOrigin('https://[fd00::5]:9000')!.signaling,
        'https://[fd00::5]:9000/v1/stream',
      );
      expect(KovapilotEndpoints.fromOrigin('https://8.8.8.8:8082'), isNull);
      expect(KovapilotEndpoints.fromOrigin(null), isNull);
    });
  });

  group('IP로 연결 input', () {
    ({String host, int port})? parse(String text, [List<String>? errors]) =>
        parseCommaAddress(text, onError: errors?.add);

    test('IP, IP:port, IPv6 in brackets; 8082 when left out', () {
      expect(parse('192.168.43.20'), (host: '192.168.43.20', port: 8082));
      expect(parse(' 10.0.0.5 '), (host: '10.0.0.5', port: 8082));
      expect(parse('172.20.10.2:9000'), (host: '172.20.10.2', port: 9000));
      expect(parse('[fd00::5]:8082'), (host: 'fd00::5', port: 8082));
      expect(parse('fe80::1'), (host: 'fe80::1', port: 8082));
    });

    test('public IPs, bad ports and other text are refused with a reason', () {
      for (final (text, reason) in [
        ('', CommaAddressText.empty),
        ('8.8.8.8', CommaAddressText.notLocal),
        ('203.0.113.9:8082', CommaAddressText.notLocal),
        ('192.168.0.1:0', CommaAddressText.port),
        ('192.168.0.1:70000', CommaAddressText.port),
        ('192.168.0.1:80a', CommaAddressText.port),
        ('192.168.0.1:', CommaAddressText.port),
        ('http://192.168.0.1', CommaAddressText.format),
        ('my-comma', CommaAddressText.format),
        ('192.168.0.1 8082', CommaAddressText.format),
        ('[fd00::5', CommaAddressText.format),
        ('010.0.0.1', CommaAddressText.format),
      ]) {
        final errors = <String>[];
        expect(parse(text, errors), isNull, reason: text);
        expect(errors, [reason], reason: text);
      }
    });

    test('where the comma shows its IP uses the comma\'s own menu names', () {
      expect(CommaAddressText.whereToFind, contains('네트워크'));
      expect(CommaAddressText.whereToFind, contains('고급'));
      expect(CommaAddressText.whereToFind, contains('IP 주소'));
    });
  });
}
