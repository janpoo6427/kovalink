// The comma got a new IP while telemetry was live: the old socket may stay
// half-open, so the app swaps it for the one at the new address as soon as
// that one opens, and pings Wi-Fi sockets so a dead one is closed.
// Real TLS servers on 127.0.0.2 and 127.0.0.3 with the same certificate.
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/network/gateway_session.dart';
import 'package:kovalink/src/network/kovapilot_endpoints.dart';
import 'package:kovalink/src/services/gateway_controller.dart';

import 'support/fake_wifi_gateway.dart';

GatewaySession _session(FakeWifiGateway gateway) => GatewaySession(
  endpoints: KovapilotEndpoints(
    host: gateway.address,
    port: gateway.port,
    secure: true,
  ),
  credentials: GatewayCredentials(
    pin: fixturePin(pinDeviceA),
    token: testToken,
  ),
);

void main() {
  test('a live socket to the old IP is swapped for the new IP', () async {
    final before = await FakeWifiGateway.start(address: '127.0.0.2');
    final after = await FakeWifiGateway.start(address: '127.0.0.3');
    final first = _session(before);
    final second = _session(after);
    final gateway = GatewayController()..startDemo();
    var leftLive = 0;
    gateway.addListener(() {
      if (gateway.mode != GatewayMode.live) leftLive++;
    });
    addTearDown(() async {
      gateway.dispose();
      first.close();
      second.close();
      await before.close();
      await after.close();
    });

    expect(
      await gateway.connectInBackground(
        first.endpoints.telemetry,
        session: first,
      ),
      isTrue,
    );
    expect(gateway.connectedEndpoint, first.endpoints.telemetry);
    leftLive = 0;

    // Same address again: nothing new is opened.
    expect(
      await gateway.connectInBackground(
        first.endpoints.telemetry,
        session: first,
      ),
      isTrue,
    );
    expect(before.sockets, hasLength(1));

    expect(
      await gateway.connectInBackground(
        second.endpoints.telemetry,
        session: second,
      ),
      isTrue,
    );
    expect(gateway.mode, GatewayMode.live);
    expect(gateway.connectedEndpoint, second.endpoints.telemetry);
    expect(gateway.gatewayAuthenticated, isTrue);
    expect(after.sockets, hasLength(1));
    expect(leftLive, 0, reason: 'never shown as dropped while swapping');
    expect(
      after.requests.where((r) => r.upgrade).single.authorization,
      'Bearer $testToken',
    );
  });

  test(
    'without a session a live socket is kept (development loopback)',
    () async {
      final comma = await FakeWifiGateway.start(address: '127.0.0.2');
      final session = _session(comma);
      final gateway = GatewayController();
      addTearDown(() async {
        gateway.dispose();
        session.close();
        await comma.close();
      });
      expect(
        await gateway.connectInBackground(
          session.endpoints.telemetry,
          session: session,
        ),
        isTrue,
      );
      expect(
        await gateway.connectInBackground('ws://127.0.0.1:9/v1/telemetry'),
        isTrue,
      );
      expect(gateway.connectedEndpoint, session.endpoints.telemetry);
    },
  );

  test('Wi-Fi telemetry sockets are pinged so a dead one closes', () async {
    final comma = await FakeWifiGateway.start(address: '127.0.0.2');
    final session = _session(comma);
    addTearDown(() async {
      session.close();
      await comma.close();
    });
    final socket = await session.openWebSocket(session.endpoints.telemetry);
    expect(socket.pingInterval, GatewaySession.telemetryPing);
    expect(GatewaySession.telemetryPing, const Duration(seconds: 5));
    await socket.close();
  });
}
