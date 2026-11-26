import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/network/comma_registry.dart';
import 'package:kovalink/src/network/tailscale_vpn.dart';

void main() {
  test('the VPN credential is derived for the read-only endpoint', () {
    expect(
      TailscaleVpnClient.readToken('a' * 64),
      'a5027aa222ec5f1acebedab5b86bb4df75fe5114c97bc743361beee5d644de3c',
    );
  });

  test('only official device-login links can open the browser', () {
    const valid = 'https://login.tailscale.com/a/abc123';
    expect(TailscaleVpnClient.loginUri(valid), Uri.parse(valid));
    for (final url in [
      'http://login.tailscale.com/a/abc123',
      'https://login.tailscale.com.evil.example/a/abc123',
      'https://login.tailscale.com@elsewhere.example/a/abc123',
      'https://login.tailscale.com/a/abc123?next=elsewhere.example',
      'https://login.tailscale.com/',
    ]) {
      expect(TailscaleVpnClient.loginUri(url), isNull);
    }
  });

  test('only the comma VPN IP is persisted with the registered comma', () {
    final json = {'pin': 'a' * 64, 'host': '192.168.1.20', 'port': 8082};
    final comma = RegisteredComma.fromJson(json)!;
    expect(comma.vpnHost, isNull);
    final registered = comma.withVpnHost('100.64.12.1');
    expect(RegisteredComma.fromJson(registered.toJson()), registered);
    expect(registered.at('192.168.1.21', 8082).vpnHost, registered.vpnHost);
    for (final invalid in [
      'evil.example',
      'comma.tail-test.ts.net',
      '100.128.0.1',
      '192.168.1.20',
      '100.64.12.1:8083',
      '100.064.12.1',
    ]) {
      expect(
        RegisteredComma.fromJson({...json, 'vpnHost': invalid})!.vpnHost,
        isNull,
      );
    }
  });
}
