// The one client every Wi-Fi request uses: the certificate pin decides,
// the token goes out only after it matched, WebSockets carry no Origin.
// Real TLS servers on the standard loopback address with fixture certificates.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/network/gateway_pin.dart';
import 'package:kovalink/src/network/gateway_session.dart';
import 'package:kovalink/src/network/kovapilot_endpoints.dart';
import 'package:kovalink/src/services/web_rtc_road_stream.dart';

import 'support/fake_wifi_gateway.dart';

GatewaySession _session(
  FakeWifiGateway gateway, {
  String pin = pinDeviceA,
  String token = testToken,
  SecurityContext Function()? context,
}) => GatewaySession(
  endpoints: KovapilotEndpoints(
    host: gateway.address,
    port: gateway.port,
    secure: true,
  ),
  credentials: GatewayCredentials(pin: fixturePin(pin), token: token),
  context: context,
);

KovaParamsClient _client(GatewaySession session) => KovaParamsClient(
  Uri.parse(session.endpoints.origin),
  transport: session.transport,
  timeout: const Duration(seconds: 3),
);

Future<FakeWifiGateway> _startGateway({String cert = 'device_a'}) async {
  final gateway = await FakeWifiGateway.start(address: '127.0.0.1', cert: cert);
  addTearDown(gateway.close);
  return gateway;
}

void main() {
  test('matching pin: the request carries the token', () async {
    final gateway = await _startGateway();
    final session = _session(gateway);
    addTearDown(session.close);
    final health = await _client(session).health();
    expect(health.bindScope, 'wifi');
    expect(health.authentication, 'bearer');
    expect(gateway.requests.single.authorization, 'Bearer $testToken');
    expect(gateway.requests.single.origin, isNull);
    expect(gateway.requests.single.host, '${gateway.address}:${gateway.port}');
    expect(session.lastPresented?.hex, pinDeviceA);
  });

  test('another certificate: refused before anything is sent', () async {
    final gateway = await _startGateway(cert: 'device_b');
    final session = _session(gateway);
    addTearDown(session.close);
    await expectLater(
      _client(session).health(),
      throwsA(
        isA<KovaParamsException>().having(
          (e) => e.kind,
          'kind',
          KovaFailureKind.identity,
        ),
      ),
    );
    expect(gateway.requestCount, 0, reason: 'no HTTP request, no token');
    expect(session.lastPresented?.hex, pinDeviceB);
  });

  test(
    'a chain: the comma\'s own (first) certificate is what counts',
    () async {
      final gateway = await _startGateway(cert: 'chain');
      final leaf = _session(gateway, pin: pinChainLeaf);
      addTearDown(leaf.close);
      expect((await _client(leaf).health()).status, 'ok');

      final caPinned = _session(gateway, pin: pinTestCa);
      addTearDown(caPinned.close);
      await expectLater(
        _client(caPinned).health(),
        throwsA(isA<KovaParamsException>()),
      );
      expect(gateway.requestCount, 1);
    },
  );

  test('a certificate the trust store accepts is still pin-checked', () async {
    // As if the comma had a publicly trusted certificate: the test CA is
    // trusted here and the chain verifies, IP SAN included.
    final gateway = await _startGateway(cert: 'chain');
    SecurityContext trusting() =>
        SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates('$tlsFixtures/ca.pem');
    final other = _session(gateway, pin: pinDeviceA, context: trusting);
    addTearDown(other.close);
    await expectLater(
      _client(other).health(),
      throwsA(
        isA<KovaParamsException>().having(
          (e) => e.kind,
          'kind',
          KovaFailureKind.identity,
        ),
      ),
    );
    expect(gateway.requestCount, 0);
    final right = _session(gateway, pin: pinChainLeaf, context: trusting);
    addTearDown(right.close);
    expect((await _client(right).health()).status, 'ok');
  });

  test('a wrong token is 401: unauthorized, with the plain message', () async {
    final gateway = await _startGateway();
    final session = _session(gateway, token: 'ff' * 32);
    addTearDown(session.close);
    await expectLater(
      _client(session).health(),
      throwsA(
        isA<KovaParamsException>()
            .having((e) => e.kind, 'kind', KovaFailureKind.unauthorized)
            .having((e) => e.message, 'message', contains('연결 토큰')),
      ),
    );
  });

  test('settings, telemetry, camera and Git share the one client', () async {
    final gateway = await _startGateway();
    final session = _session(gateway);
    addTearDown(session.close);
    final client = _client(session);
    final document = await client.fetch();
    final update = await client.update(
      'steering.always_on',
      true,
      document.revision,
    );
    expect(update, isA<KovaUpdateApplied>());

    final ws = await session.openWebSocket(session.endpoints.telemetry);
    final frame = jsonDecode(await ws.first as String) as Map;
    expect(frame['speedMps'], 7.5);
    await ws.close();

    final answer = await postKovapilotOffer(
      Uri.parse(session.endpoints.signaling),
      sdp: 'v=0 offer',
      camera: 'road',
      session: session,
    );
    expect(answer.type, 'answer');
    expect(gateway.streamBodies.single['cameras'], ['road']);

    final git = await session.transport.get(
      session.endpoints.git('status'),
      const Duration(seconds: 3),
    );
    expect(git.statusCode, 200);

    expect(gateway.requests, hasLength(5));
    for (final r in gateway.requests) {
      expect(r.authorization, 'Bearer $testToken', reason: r.path);
      expect(r.origin, isNull, reason: '${r.path}: no Origin header');
    }
    expect(gateway.requests.where((r) => r.upgrade), hasLength(1));
  });

  test('the session refuses any other address', () async {
    final gateway = await _startGateway();
    final session = _session(gateway);
    addTearDown(session.close);
    await expectLater(
      session.openWebSocket('wss://127.0.0.3:${gateway.port}/v1/telemetry'),
      throwsA(isA<GatewayOriginRefused>()),
    );
    await expectLater(
      session.client.getUrl(Uri.parse('https://127.0.0.3:${gateway.port}/')),
      throwsA(isA<GatewayOriginRefused>()),
    );
    expect(session.covers(Uri.parse(gateway.origin)), isTrue);
    expect(
      session.covers(Uri.parse('http://${gateway.address}:${gateway.port}')),
      isFalse,
    );
    expect(gateway.requestCount, 0);
  });

  test('a loopback development gateway never gets a token', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String?>[];
    server.listen((request) {
      seen.add(request.headers.value(HttpHeaders.authorizationHeader));
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"status":"ok","schemaVersion":1,"bindScope":"loopback"}')
        ..close();
    });
    final session = GatewaySession(
      endpoints: KovapilotEndpoints.device('127.0.0.1', server.port),
    );
    addTearDown(() async {
      session.close();
      await server.close(force: true);
    });
    expect(session.sendsToken, isFalse);
    expect((await _client(session).health()).bindScope, 'loopback');
    expect(seen, [null]);
    expect(
      () =>
          GatewaySession(endpoints: KovapilotEndpoints.device('192.168.43.20')),
      throwsArgumentError,
    );
  });

  test('tokens: 64 hex digits, lowercased; never in toString', () {
    expect(
      GatewayCredentials.normalizeToken(' ${testToken.toUpperCase()} '),
      testToken,
    );
    expect(GatewayCredentials.normalizeToken(testToken.substring(2)), isNull);
    expect(GatewayCredentials.normalizeToken('g' * 64), isNull);
    final credentials = GatewayCredentials(
      pin: fixturePin(pinDeviceA),
      token: testToken,
    );
    expect(credentials.toString(), isNot(contains(testToken)));
    expect(
      GatewayIdentityMismatch(fixturePin(pinDeviceB)).toString(),
      isNot(contains(testToken)),
    );
  });
}
