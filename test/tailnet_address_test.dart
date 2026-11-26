// The comma's VPN IP (Tailscale 100.x): accepted as an address, port 8083,
// and tried only while this phone is on the tailnet.
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/network/comma_registry.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/kovapilot_endpoints.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';

void main() {
  test('only the Tailscale range counts as a VPN IP', () {
    for (final ip in ['100.64.0.1', '100.71.162.38', '100.127.255.254']) {
      expect(LocalEndpointPolicy.isTailnetAddress(ip), isTrue, reason: ip);
      expect(isPolicyTarget(ip, kovaGatewayTailnetPort), isTrue, reason: ip);
    }
    for (final ip in [
      '100.63.255.255',
      '100.128.0.1',
      '100.071.162.38',
      '8.8.8.8',
      'comma.tail1234.ts.net',
    ]) {
      expect(LocalEndpointPolicy.isTailnetAddress(ip), isFalse, reason: ip);
    }
  });

  test('IP 입력: a VPN IP goes to the VPN port unless one is given', () {
    expect(parseCommaAddress('100.71.162.38'), (
      host: '100.71.162.38',
      port: kovaGatewayTailnetPort,
    ));
    expect(parseCommaAddress('100.71.162.38:9000'), (
      host: '100.71.162.38',
      port: 9000,
    ));
    expect(parseCommaAddress('192.168.0.20'), (
      host: '192.168.0.20',
      port: kovaGatewayDefaultPort,
    ));
    String? reason;
    expect(parseCommaAddress('8.8.8.8', onError: (r) => reason = r), isNull);
    expect(reason, contains('VPN IP(100.x)'));
  });

  test('the VPN endpoint is planned only on the tailnet', () {
    const vpn = 'https://100.71.162.38:8083';
    final wifi = LocalNetwork.named('wlan0', '192.168.0.7');
    final tailnet = LocalNetwork.named('tun0', '100.88.1.2');
    final carrier = LocalNetwork.named('rmnet_data0', '100.70.3.4');

    bool planned(List<LocalNetwork> networks) => DiscoveryPlan.build(
      networks: networks,
      knownEndpoints: const [vpn],
    ).priority.any((t) => t.host == '100.71.162.38' && t.port == 8083);

    expect(planned([wifi, tailnet]), isTrue);
    expect(planned([tailnet]), isTrue, reason: 'mobile data with Tailscale on');
    expect(planned([wifi]), isFalse, reason: 'Tailscale off on the phone');
    expect(
      planned([carrier]),
      isFalse,
      reason: 'a carrier 100.x is not the tailnet',
    );
    final plan = DiscoveryPlan.build(
      networks: [wifi, tailnet],
      lastEndpoint: 'https://192.168.0.20:8082',
      knownEndpoints: const [vpn],
    );
    expect(plan.priority.first.host, '192.168.0.20', reason: 'Wi-Fi first');
  });

  test(
    'the registered comma keeps its VPN IP apart from its Wi-Fi address',
    () {
      final json = {'pin': 'a' * 64, 'host': '192.168.1.20', 'port': 8082};
      final comma = RegisteredComma.fromJson(
        json,
      )!.withVpnHost('100.71.162.38');
      expect(comma.vpnEndpoint, 'https://100.71.162.38:8083');
      expect(comma.endpoints.origin, 'https://192.168.1.20:8082');
      expect(RegisteredComma.fromJson(comma.toJson()), comma);
    },
  );
}
